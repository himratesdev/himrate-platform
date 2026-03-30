# frozen_string_literal: true

# TASK-026: Base adapter for bot list sources.
# Each adapter: #fetch → Array<String> (usernames), #source_name → String, #bot_category → String

module BotSources
  class BaseAdapter
    REQUEST_TIMEOUT = 30
    USER_AGENT = "HimRate/1.0 (bot-detection; https://himrate.com)"

    def fetch
      raise NotImplementedError, "#{self.class}#fetch must be implemented"
    end

    def source_name
      raise NotImplementedError
    end

    def bot_category
      "unknown"
    end

    private

    # Uses http gem (gem "http" ~> 5.0 in Gemfile)
    def http_get(url, timeout: REQUEST_TIMEOUT)
      response = HTTP.timeout(timeout).headers("User-Agent" => USER_AGENT).get(url)
      return nil unless response.status.to_i == 200

      response.body.to_s
    rescue HTTP::TimeoutError => e
      Rails.logger.warn("#{self.class}: timeout fetching #{url} (#{e.message})")
      nil
    rescue HTTP::ConnectionError => e
      Rails.logger.warn("#{self.class}: connection error #{url} (#{e.message})")
      nil
    end
  end
end
