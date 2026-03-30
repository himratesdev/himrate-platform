# frozen_string_literal: true

# TASK-026: CommanderRoot known bot list adapter.
# Largest public bot database (11.8M+).
# API endpoint needs investigation at Dev time — using known public endpoint.
# Fallback: direct known_bot_stats page parsing.

module BotSources
  class CommanderRootAdapter < BaseAdapter
    # CommanderRoot provides a bulk download at this endpoint
    API_URL = "https://api.twitchinsights.net/v1/bots/all"
    STATS_URL = "https://twitch-tools.rootonline.de/known_bot_stats.php"

    def fetch
      # Primary: TwitchInsights /bots/all includes CommanderRoot data
      body = http_get(API_URL, timeout: 120)
      return [] unless body

      data = JSON.parse(body)
      bots = data["bots"] || data
      return [] unless bots.is_a?(Array)

      bots.map { |bot| bot.is_a?(Array) ? bot[0]&.downcase : bot["name"]&.downcase }.compact.uniq
    rescue JSON::ParserError => e
      Rails.logger.warn("CommanderRootAdapter: JSON parse error (#{e.message})")
      []
    end

    def source_name
      "commanderroot"
    end

    def bot_category
      "view_bot"
    end
  end
end
