# frozen_string_literal: true

namespace :channels do
  desc "TASK-251.12: seed + pin the curated RU-streamer list (db/seeds/curated_channels.yml)"
  task seed_curated: :environment do
    result = Channels::CuratedSeeder.call
    puts "CuratedSeeder: pinned=#{result.pinned} unresolved=#{result.unresolved.size}"
    puts "Unresolved logins: #{result.unresolved.inspect}" if result.unresolved.any?
  end
end
