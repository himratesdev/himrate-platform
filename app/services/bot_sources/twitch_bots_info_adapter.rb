# frozen_string_literal: true

# TASK-026: twitchbots.info adapter.
# API: https://api.twitchbots.info/v2/bot (paginated, 100/page)
# Returns service bots (Nightbot, Moobot, StreamElements, etc.)

module BotSources
  class TwitchBotsInfoAdapter < BaseAdapter
    API_URL = "https://api.twitchbots.info/v2/bot"
    PER_PAGE = 100
    MAX_PAGES = 20 # safety limit: 2000 bots max

    def fetch
      all_bots = []
      offset = 0

      MAX_PAGES.times do
        body = http_get("#{API_URL}?limit=#{PER_PAGE}&offset=#{offset}")
        break unless body

        data = JSON.parse(body)
        bots = data["bots"] || []
        break if bots.empty?

        all_bots.concat(bots.map { |b| b["userName"]&.downcase }.compact)
        offset += PER_PAGE
        break if bots.size < PER_PAGE
      end

      all_bots.uniq
    rescue JSON::ParserError => e
      Rails.logger.warn("TwitchBotsInfoAdapter: JSON parse error (#{e.message})")
      all_bots.uniq
    end

    def source_name
      "twitchbots_info"
    end

    def bot_category
      "service_bot"
    end
  end
end
