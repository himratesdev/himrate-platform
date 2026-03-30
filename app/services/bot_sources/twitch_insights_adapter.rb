# frozen_string_literal: true

# TASK-026: TwitchInsights bot list adapter.
# API: https://api.twitchinsights.net/v1/bots/online
# Returns JSON array of currently online bots.

module BotSources
  class TwitchInsightsAdapter < BaseAdapter
    API_URL = "https://api.twitchinsights.net/v1/bots/online"

    def fetch
      body = http_get(API_URL)
      return [] unless body

      data = JSON.parse(body)
      bots = data["bots"] || data
      return [] unless bots.is_a?(Array)

      bots.map { |bot| bot.is_a?(Array) ? bot[0]&.downcase : bot["name"]&.downcase }.compact.uniq
    rescue JSON::ParserError => e
      Rails.logger.warn("TwitchInsightsAdapter: JSON parse error (#{e.message})")
      []
    end

    def source_name
      "twitchinsights"
    end

    def bot_category
      "view_bot"
    end
  end
end
