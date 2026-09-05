# frozen_string_literal: true

namespace :farm do
  namespace :capture do
    desc "EPIC FARM T-F1: seed/upsert capture-set categories (db/seeds/farm_capture_categories.yml)"
    task seed_categories: :environment do
      result = Farm::CaptureCategorySeeder.call
      puts "CaptureCategorySeeder: created=#{result.created} updated=#{result.updated}"
      FarmCaptureCategory.order(:game_name).each do |c|
        puts "  #{c.game_id} #{c.game_name} languages=#{c.languages.inspect} floor=#{c.viewer_floor} enabled=#{c.enabled}"
      end
    end

    desc "EPIC FARM T-F1: print the live capture set (Redis) — size per category + pool heartbeat"
    task status: :environment do
      set = Farm::CaptureSet.new
      entries = set.entries
      puts "capture set: #{entries.size} channels"
      entries.values.group_by { |e| e["game_id"] }.each do |game_id, rows|
        puts "  game_id=#{game_id}: #{rows.size}"
      end
      puts "pool heartbeat: #{set.pool_heartbeat.inspect}"
    end
  end
end
