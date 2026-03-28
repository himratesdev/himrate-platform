# frozen_string_literal: true

# TASK-021: Twitch Helix API Client
# App access token (client_credentials) cached in Redis.
# Rate limiting: 800 points/min via Ratelimit-Remaining header.
# Exponential backoff on 429. Auto-refresh on 401.

module Twitch
  class HelixClient
    BASE_URL = "https://api.twitch.tv/helix"
    TOKEN_URL = "https://id.twitch.tv/oauth2/token"
    TOKEN_CACHE_KEY = "twitch:app_access_token"
    REQUEST_TIMEOUT = 5
    MAX_RETRIES = 3
    BACKOFF_BASE = 1 # seconds

    class Error < StandardError; end
    class RateLimitError < Error; end
    class AuthError < Error; end

    def initialize
      @client_id = ENV.fetch("TWITCH_CLIENT_ID") { raise Error, "TWITCH_CLIENT_ID not set" }
      @client_secret = ENV.fetch("TWITCH_CLIENT_SECRET") { raise Error, "TWITCH_CLIENT_SECRET not set" }
    end

    # === Public API methods ===

    def get_users(logins: [], ids: [])
      params = {}
      params[:login] = logins if logins.any?
      params[:id] = ids if ids.any?
      get("/users", params)&.dig("data")
    end

    def get_streams(user_logins: [], user_ids: [])
      params = {}
      params[:user_login] = user_logins if user_logins.any?
      params[:user_id] = user_ids if user_ids.any?
      get("/streams", params)&.dig("data")
    end

    def get_channel_info(broadcaster_id:)
      get("/channels", { broadcaster_id: broadcaster_id })&.dig("data")&.first
    end

    def get_followers_count(broadcaster_id:)
      get("/channels/followers", { broadcaster_id: broadcaster_id, first: 1 })&.dig("total")
    end

    def get_clips(broadcaster_id:, first: 20)
      get("/clips", { broadcaster_id: broadcaster_id, first: first })&.dig("data")
    end

    private

    # === HTTP ===

    def get(path, params = {}, retries: 0)
      token = fetch_app_token
      uri = build_uri(path, params)

      response = HTTP.timeout(REQUEST_TIMEOUT).headers(
        "Client-ID" => @client_id,
        "Authorization" => "Bearer #{token}"
      ).get(uri)

      track_rate_limit(response)

      case response.status.to_i
      when 200
        JSON.parse(response.body.to_s)
      when 401
        invalidate_token
        retries < 1 ? get(path, params, retries: retries + 1) : handle_error(response, path)
      when 429
        handle_rate_limit(response, path, params, retries)
      when 500, 502, 503
        handle_server_error(response, path, params, retries)
      else
        handle_error(response, path)
      end
    rescue HTTP::TimeoutError => e
      Rails.logger.error("Twitch Helix timeout: #{path} (#{e.message})")
      nil
    rescue HTTP::ConnectionError => e
      Rails.logger.error("Twitch Helix connection error: #{path} (#{e.message})")
      nil
    end

    def build_uri(path, params)
      uri = URI("#{BASE_URL}#{path}")
      # Handle array params (login=x&login=y)
      query_parts = params.flat_map do |key, value|
        Array(value).map { |v| "#{key}=#{CGI.escape(v.to_s)}" }
      end
      uri.query = query_parts.join("&") if query_parts.any?
      uri.to_s
    end

    # === Token management ===

    def fetch_app_token
      cached = redis&.get(TOKEN_CACHE_KEY)
      return cached if cached.present?

      response = HTTP.post(TOKEN_URL, form: {
        client_id: @client_id,
        client_secret: @client_secret,
        grant_type: "client_credentials"
      })

      unless response.status.to_i == 200
        raise AuthError, "Failed to obtain app access token: #{response.status}"
      end

      data = JSON.parse(response.body.to_s)
      token = data["access_token"]
      expires_in = data["expires_in"].to_i

      # Cache with buffer (60s before expiry)
      ttl = [ expires_in - 60, 60 ].max
      redis&.setex(TOKEN_CACHE_KEY, ttl, token)

      token
    end

    def invalidate_token
      redis&.del(TOKEN_CACHE_KEY)
    end

    def redis
      @redis ||= begin
        r = Redis.new(url: ENV.fetch("REDIS_URL", "redis://localhost:6379/1"))
        r.ping
        r
      rescue Redis::CannotConnectError, Redis::TimeoutError => e
        Rails.logger.warn("Twitch::HelixClient: Redis unavailable (#{e.message}), token caching disabled")
        nil
      end
    end

    # === Error handling ===

    def handle_rate_limit(response, path, params, retries)
      if retries >= MAX_RETRIES
        Rails.logger.error("Twitch Helix rate limit exhausted: #{path} after #{MAX_RETRIES} retries")
        return nil
      end

      reset_epoch = response.headers["Ratelimit-Reset"]&.to_i
      wait = if reset_epoch && reset_epoch > Time.current.to_i
        [ reset_epoch - Time.current.to_i + 1, 60 ].min # cap at 60s
      else
        BACKOFF_BASE * (2**retries)
      end

      Rails.logger.warn("Twitch Helix 429: #{path}, waiting #{wait}s (retry #{retries + 1})")
      sleep(wait)
      get(path, params, retries: retries + 1)
    end

    def handle_server_error(response, path, params, retries)
      if retries >= MAX_RETRIES
        Rails.logger.error("Twitch Helix #{response.status}: #{path} after #{MAX_RETRIES} retries")
        nil
      else
        wait = BACKOFF_BASE * (2**retries)
        Rails.logger.warn("Twitch Helix #{response.status}: #{path}, retry #{retries + 1} in #{wait}s")
        sleep(wait)
        get(path, params, retries: retries + 1)
      end
    end

    def handle_error(response, path)
      Rails.logger.error("Twitch Helix error #{response.status}: #{path} — #{response.body.to_s.truncate(200)}")
      nil
    end

    def track_rate_limit(response)
      remaining = response.headers["Ratelimit-Remaining"]&.to_i
      return unless remaining

      if remaining < 50
        Rails.logger.warn("Twitch Helix rate limit low: #{remaining} remaining")
      end
    end
  end
end
