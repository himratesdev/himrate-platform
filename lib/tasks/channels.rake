# frozen_string_literal: true

namespace :channels do
  desc "TASK-251.12: seed + pin the curated RU-streamer list (db/seeds/curated_channels.yml)"
  task seed_curated: :environment do
    result = Channels::CuratedSeeder.call
    puts "CuratedSeeder: pinned=#{result.pinned} unresolved=#{result.unresolved.size}"
    puts "Unresolved logins: #{result.unresolved.inspect}" if result.unresolved.any?
  end

  desc "TASK-251.2: preview the channel prune (dry-run, read-only, no changes)"
  task prune_dry_run: :environment do
    result = ChannelPruneWorker.new.preview
    puts "ChannelPruneWorker dry-run: would unmonitor #{result[:count]} banned non-pinned channels (per run; bounded by MAX_PER_RUN)"
    puts "Sample: #{result[:sample].inspect}"
  end
end
