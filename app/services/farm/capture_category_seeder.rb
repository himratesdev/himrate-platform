# frozen_string_literal: true

module Farm
  # EPIC FARM T-F1: upsert the capture-set categories from db/seeds/farm_capture_categories.yml.
  # Idempotent — re-running updates name / languages / floor in place, never duplicates a game_id,
  # and never deletes rows (disable a category by setting enabled: false, not by removing it).
  class CaptureCategorySeeder
    SEED_PATH = Rails.root.join("db/seeds/farm_capture_categories.yml")

    Result = Struct.new(:created, :updated, keyword_init: true)

    def self.call(entries: nil) = new(entries: entries).call

    def self.load_seed
      YAML.safe_load_file(SEED_PATH) || []
    end

    def initialize(entries: nil)
      @entries = entries || self.class.load_seed
      @created = 0
      @updated = 0
    end

    def call
      @entries.each { |entry| upsert(entry.with_indifferent_access) }
      Rails.logger.info("Farm::CaptureCategorySeeder: created=#{@created} updated=#{@updated}")
      Result.new(created: @created, updated: @updated)
    end

    private

    def upsert(entry)
      row = FarmCaptureCategory.find_or_initialize_by(game_id: entry[:game_id].to_s)
      was_new = row.new_record?
      row.assign_attributes(
        game_name: entry[:game_name],
        languages: Array(entry[:languages]).map { |l| l.to_s.downcase }.presence,
        viewer_floor: entry.fetch(:viewer_floor, 0).to_i,
        enabled: entry.key?(:enabled) ? entry[:enabled] : row.enabled
      )
      row.save!
      was_new ? @created += 1 : @updated += 1
    end
  end
end
