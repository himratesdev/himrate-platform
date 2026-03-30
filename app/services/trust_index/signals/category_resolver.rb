# frozen_string_literal: true

# TASK-028 FR-014: Resolve Twitch game name/ID to internal category.
# Categories: just_chatting, esports, gaming, irl, music, default.

module TrustIndex
  module Signals
    class CategoryResolver
      CATEGORIES = %w[just_chatting esports gaming irl music default].freeze

      # Twitch game names → internal category. Case-insensitive matching.
      GAME_MAP = {
        "just_chatting" => %w[
          just\ chatting talk\ shows\ &\ podcasts asmr
          pools,\ hot\ tubs,\ and\ beaches sleep
        ],
        "esports" => %w[
          counter-strike valorant league\ of\ legends dota\ 2
          overwatch\ 2 rainbow\ six\ siege rocket\ league
          call\ of\ duty:\ warzone
        ],
        "irl" => %w[
          irl travel\ &\ outdoors food\ &\ drink art
          makers\ &\ crafting special\ events fitness\ &\ health
        ],
        "music" => %w[
          music djs\ &\ djing singing
        ]
      }.freeze

      # Pre-build a reverse lookup: lowercased game name → category
      REVERSE_MAP = GAME_MAP.each_with_object({}) do |(category, games), map|
        games.each { |g| map[g.downcase] = category }
      end.freeze

      def self.resolve(game_name)
        return "default" if game_name.blank?

        normalized = game_name.to_s.downcase.strip
        REVERSE_MAP[normalized] || "gaming"
      end
    end
  end
end
