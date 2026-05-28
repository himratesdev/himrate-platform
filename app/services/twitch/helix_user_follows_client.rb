# frozen_string_literal: true

# TASK-113 Δ-1 Wave 1 (FR-016 source #1): user-scoped Twitch Helix client для GET /channels/followed.
# Uses user OAuth Bearer token from AuthProvider#access_token (scope user:read:follows required).
# Distinct from existing Twitch::HelixClient (app-scoped token для public endpoints).
#
# 401 → AuthError raised (Sidekiq retry/dead path). Refresh-on-401 deferred — Wave 2 enhancement
# (require Auth::TwitchOauth.refresh_user_token integration; mid-batch refresh пересекается with
# pagination cursor lifecycle).
# 403 → ScopeError raised (user не дал scope user:read:follows; Sentry-log + graceful empty).
# 429 → respects Ratelimit-Reset header per CR iter-1 S3 (exponential backoff up to MAX_RETRIES).
# Pagination: Helix returns up to 100 per page + `pagination.cursor`. Caller paginates до exhaustion.
#
# IMPORTANT: Call from Sidekiq workers only (not controllers). Network I/O blocking.
module Twitch
  class HelixUserFollowsClient
    BASE_URL = "https://api.twitch.tv/helix"
    REQUEST_TIMEOUT = 5
    PAGE_SIZE = 100
    MAX_RETRIES = 3
    BACKOFF_BASE = 1 # seconds

    class Error < StandardError; end
    class AuthError < Error; end
    class ScopeError < AuthError; end

    def initialize(auth_provider:)
      @auth_provider = auth_provider
      @client_id = ENV.fetch("TWITCH_CLIENT_ID") { raise Error, "TWITCH_CLIENT_ID not set" }
    end

    # Returns enumerator yielding pages: { "data" => [...], "pagination" => { "cursor" => "..." } }
    # Each entry в data: { broadcaster_id, broadcaster_login, broadcaster_name, followed_at }
    def followed_channels_pages
      Enumerator.new do |yielder|
        cursor = nil
        loop do
          response = fetch_page(cursor: cursor)
          yielder << response
          cursor = response.dig("pagination", "cursor")
          break if cursor.blank?
        end
      end
    end

    # Returns flattened array of all follow entries (consumes all pages).
    def all_followed_channels
      followed_channels_pages.flat_map { |page| page["data"] || [] }
    end

    private

    def fetch_page(cursor:, retries: 0)
      params = { user_id: @auth_provider.provider_id, first: PAGE_SIZE }
      params[:after] = cursor if cursor

      response = HTTP
        .timeout(REQUEST_TIMEOUT)
        .headers(
          "Client-ID" => @client_id,
          "Authorization" => "Bearer #{@auth_provider.access_token}"
        )
        .get("#{BASE_URL}/channels/followed", params: params)

      case response.code
      when 200
        JSON.parse(response.body.to_s)
      when 401
        raise AuthError, "User OAuth token expired (user_id=#{@auth_provider.user_id})"
      when 403
        raise ScopeError, "Missing user:read:follows scope (user_id=#{@auth_provider.user_id})"
      when 429
        # CR iter-1 S3: respect Ratelimit-Reset header + exponential backoff.
        raise Error, "Helix rate-limited (retries exhausted)" if retries >= MAX_RETRIES
        sleep(rate_limit_delay(response, retries))
        fetch_page(cursor: cursor, retries: retries + 1)
      else
        raise Error, "Helix /channels/followed responded #{response.code}: #{response.body.to_s[0, 200]}"
      end
    rescue HTTP::TimeoutError, Errno::ECONNREFUSED => e
      raise Error, "Helix /channels/followed network failure: #{e.class} #{e.message}"
    end

    def rate_limit_delay(response, retries)
      reset_at = response.headers["Ratelimit-Reset"].to_i
      delta = [ reset_at - Time.now.to_i, 0 ].max
      [ delta, BACKOFF_BASE * (2 ** retries) ].max
    end
  end
end
