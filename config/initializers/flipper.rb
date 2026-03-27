# frozen_string_literal: true

require "flipper"
require "flipper/adapters/redis"
require "flipper/adapters/active_record"
require "flipper/adapters/memoizable"

# Primary: Redis (fast). Fallback: ActiveRecord (durable).
# Memoize: per-request cache on top.
redis_url = ENV.fetch("REDIS_URL", "redis://localhost:6379/1")

begin
  redis_instance = Redis.new(url: redis_url)
  redis_adapter = Flipper::Adapters::Redis.new(redis_instance)
rescue Redis::CannotConnectError => e
  Rails.logger.error("Flipper: Redis unavailable (#{e.message}), using ActiveRecord only")
  redis_adapter = nil
end

ar_adapter = Flipper::Adapters::ActiveRecord.new

primary_adapter = redis_adapter || ar_adapter
memoized = Flipper::Adapters::Memoizable.new(primary_adapter)

Flipper.configure do |config|
  config.adapter { memoized }
end

# Instrumenter for audit logging
ActiveSupport::Notifications.subscribe(/flipper/) do |name, _start, _finish, _id, payload|
  next unless name.include?("feature_operation")

  Rails.logger.info(
    "Flipper audit: operation=#{payload[:operation]} " \
    "feature=#{payload[:feature_name]} " \
    "gate=#{payload[:gate_name]} " \
    "thing=#{payload[:thing]}"
  )
end

# Groups (per BRD BR-005)
Flipper.register(:premium_users) do |actor|
  actor.respond_to?(:tier) && actor.tier == "premium"
end

Flipper.register(:business_users) do |actor|
  actor.respond_to?(:tier) && actor.tier == "business"
end

Flipper.register(:streamers) do |actor|
  actor.respond_to?(:role) && actor.role == "streamer"
end

# Base flags (created if not exist)
base_flags = %i[
  pundit_authorization
  bot_raid_chain
  compare_unlimited
  audience_overlap
  ad_calculator
  social_presence
  panel_tracking
]

base_flags.each do |flag|
  Flipper.add(flag) unless Flipper.features.map(&:key).include?(flag.to_s)
end

# Enable pundit_authorization by default (TASK-012 migration from ENV toggle)
Flipper.enable(:pundit_authorization) unless Flipper.enabled?(:pundit_authorization)
