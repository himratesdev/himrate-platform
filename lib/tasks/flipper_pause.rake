# frozen_string_literal: true

# BUG-251.21: Tactical pause-override Redis keys for ALL_FLAGS.
#
# Pause-override survives Rails boot — unlike `Flipper.disable` which the initializer
# overrides on the next bin/rails invocation. Use this for multi-hour backfill, batch
# migration, planned maintenance windows.
#
# Mechanism: SET Redis key `flipper:pause_override:<flag>` with a reason string.
# config/initializers/flipper.rb consults this key BEFORE auto-enabling each flag.
#
# All rake tasks here use the shared Redis at REDIS_URL (the same Redis Flipper uses).
# Pause keys are NOT expired automatically — operator must explicitly clear them.
namespace :flipper do
  namespace :pause do
    desc "List active pause-overrides (flipper:pause_override:* keys)"
    task list: :environment do
      redis = Redis.new(url: ENV.fetch("REDIS_URL", "redis://localhost:6379/1"))
      prefix = FlipperDefaults::PAUSE_KEY_PREFIX
      keys = redis.scan_each(match: "#{prefix}:*").to_a.sort
      if keys.empty?
        puts "No active pause-overrides."
        next
      end
      puts "Active pause-overrides (#{keys.size}):"
      keys.each do |key|
        flag = key.delete_prefix("#{prefix}:")
        reason = redis.get(key)
        puts "  #{flag.ljust(40)} #{reason.inspect}"
      end
    rescue Redis::BaseError => e
      abort "✗ Redis unreachable: #{e.message}"
    end

    desc "Set a pause-override for a flag (survives Rails boot until cleared). " \
         "Usage: rake 'flipper:pause:set[signal_compute,backfill TASK-251.14]'"
    task :set, %i[flag reason] => :environment do |_, args|
      flag, reason = args.values_at(:flag, :reason)
      abort "Usage: rake 'flipper:pause:set[FLAG,REASON]'" if flag.blank?
      abort "✗ Reason must be provided (audit trail for operators)" if reason.blank?

      flag_sym = flag.to_sym
      known = FlipperDefaults::ALL_FLAGS.include?(flag_sym) ||
              FlipperDefaults::HOOK_FLAGS.key?(flag_sym)
      abort "✗ Unknown flag: #{flag}. Run `rake flipper:pause:flags` to list known flags." unless known

      redis = Redis.new(url: ENV.fetch("REDIS_URL", "redis://localhost:6379/1"))
      key = "#{FlipperDefaults::PAUSE_KEY_PREFIX}:#{flag}"
      redis.set(key, reason)
      puts "✓ pause-override SET: #{key} = #{reason.inspect}"
      puts "  Next Rails boot will respect this. To take effect immediately on running"
      puts "  workers, also run: redis-cli -n 1 HDEL #{flag} boolean"
    rescue Redis::BaseError => e
      abort "✗ Redis unreachable: #{e.message}"
    end

    desc "Clear a pause-override (flag returns to auto-enable on next Rails boot). " \
         "Usage: rake 'flipper:pause:clear[signal_compute]'"
    task :clear, [ :flag ] => :environment do |_, args|
      flag = args[:flag]
      abort "Usage: rake 'flipper:pause:clear[FLAG]'" if flag.blank?

      redis = Redis.new(url: ENV.fetch("REDIS_URL", "redis://localhost:6379/1"))
      key = "#{FlipperDefaults::PAUSE_KEY_PREFIX}:#{flag}"
      deleted = redis.del(key)
      if deleted.positive?
        puts "✓ pause-override CLEARED: #{key}"
        puts "  Flag will auto-enable on the next Rails boot. To enable on the running"
        puts "  workers immediately, run: bin/rails runner 'Flipper.enable(:#{flag})'"
      else
        puts "(no-op) no pause-override was set for #{flag}"
      end
    rescue Redis::BaseError => e
      abort "✗ Redis unreachable: #{e.message}"
    end

    desc "Clear ALL pause-overrides (use with care — operator sanity check required)"
    task clear_all: :environment do
      redis = Redis.new(url: ENV.fetch("REDIS_URL", "redis://localhost:6379/1"))
      prefix = FlipperDefaults::PAUSE_KEY_PREFIX
      keys = redis.scan_each(match: "#{prefix}:*").to_a
      if keys.empty?
        puts "No pause-overrides to clear."
        next
      end
      puts "About to clear #{keys.size} pause-override(s):"
      keys.each { |k| puts "  - #{k.delete_prefix("#{prefix}:")}" }
      deleted = redis.del(*keys)
      puts "✓ Cleared #{deleted} key(s). Flags will auto-enable on next Rails boot."
    rescue Redis::BaseError => e
      abort "✗ Redis unreachable: #{e.message}"
    end

    desc "List all known flags (ALL_FLAGS + HOOK_FLAGS) for pause-override targeting"
    task flags: :environment do
      puts "ALL_FLAGS (auto-enabled on boot unless paused — #{FlipperDefaults::ALL_FLAGS.size} flags):"
      FlipperDefaults::ALL_FLAGS.sort.each { |f| puts "  #{f}" }
      puts ""
      puts "HOOK_FLAGS (registered only, not auto-enabled — #{FlipperDefaults::HOOK_FLAGS.size} flags):"
      FlipperDefaults::HOOK_FLAGS.sort.each { |f, ref| puts "  #{f.to_s.ljust(40)} #{ref}" }
      puts ""
      puts "Pause-override applies to ALL_FLAGS (overriding the auto-enable). For HOOK_FLAGS"
      puts "pause-override has no effect since they are not auto-enabled to begin with."
    end
  end
end
