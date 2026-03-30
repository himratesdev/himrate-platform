# frozen_string_literal: true

# TASK-026: Streams Charts bot list adapter.
# Web: https://streamscharts.com/tools/bots
# API: needs investigation — may require scraping or manual import.
# Stub adapter for now — returns empty until API is researched.

module BotSources
  class StreamsChartsAdapter < BaseAdapter
    def fetch
      # TODO: Research Streams Charts API or scraping approach.
      # For now, returns empty. Bloom Filter works without this source.
      # Tracked in open questions SRS §14.
      Rails.logger.info("StreamsChartsAdapter: API not yet implemented, returning empty")
      []
    end

    def source_name
      "streamscharts"
    end

    def bot_category
      "unknown"
    end
  end
end
