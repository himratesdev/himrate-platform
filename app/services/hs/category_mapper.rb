# frozen_string_literal: true

# TASK-038 FR-015 / AR-10: Map Twitch game_name to category key via DB aliases.
# Normalize: lowercase, trim, replace ":" with space, squash multiple spaces.
# Fallback: HealthScoreCategory.default!

module Hs
  class CategoryMapper
    class << self
      # Returns category key string. Always returns a valid key (default if no match).
      def map(game_name)
        return default_key if game_name.blank?

        # Try exact alias match first (case-insensitive)
        alias_record = HealthScoreCategoryAlias
          .where("LOWER(game_name_alias) = ?", game_name.to_s.downcase.strip)
          .first
        return alias_record.health_score_category.key if alias_record

        # Try normalized key match
        normalized = normalize(game_name)
        category = HealthScoreCategory.find_by(key: normalized)
        return category.key if category

        default_key
      end

      # Normalize game_name into a lookup key format.
      # "Grand Theft Auto V" → "grand_theft_auto_v"
      # "Counter-Strike: Global Offensive" → "counter_strike_global_offensive"
      def normalize(game_name)
        game_name.to_s
          .downcase
          .strip
          .gsub(/[:\-\.\!\?\(\)]/, " ")
          .gsub(/\s+/, "_")
          .gsub(/[^a-z0-9_]/, "")
          .gsub(/_+/, "_")
          .gsub(/^_|_$/, "")
      end

      def default_key
        @default_key ||= HealthScoreCategory.default!.key
      end

      # Reset memoization (for specs)
      def reset!
        @default_key = nil
      end
    end
  end
end
