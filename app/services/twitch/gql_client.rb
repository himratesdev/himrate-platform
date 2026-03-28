# frozen_string_literal: true

# TASK-022: Twitch GQL Client
# POST requests to gql.twitch.tv/gql with public Client-ID.
# 11 operations + batch support. No OAuth required for read-only.
#
# IMPORTANT: Call from Sidekiq workers only (not controllers).
# sleep() in retry handlers blocks the thread — unacceptable in web request cycle.
#
# Integrity-protected operations (chatters, socialMedias, hasPrime/hasTurbo)
# are NOT available server-side — must be called from Extension (browser context).

module Twitch
  class GqlClient
    GQL_URL = "https://gql.twitch.tv/gql"
    DEFAULT_CLIENT_ID = "kimne78kx3ncx6brgo4mv6wki5h1ko"
    REQUEST_TIMEOUT = 5
    MAX_RETRIES = 3
    BACKOFF_BASE = 1 # seconds
    MAX_BATCH_SIZE = 35
    USER_AGENT = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"

    class Error < StandardError; end
    class RateLimitError < Error; end

    def initialize
      @client_id = ENV.fetch("TWITCH_GQL_CLIENT_ID", DEFAULT_CLIENT_ID)
    end

    # === Public API methods ===

    # FR-001: User profile for bot scoring (BotCheck)
    def bot_check(login:)
      return nil if login.blank?

      result = execute(QUERIES[:bot_check], { login: login })
      parse_user_profile(result&.dig("data", "user"))
    end

    # FR-002: Batch bot_check (up to MAX_BATCH_SIZE per request)
    def batch_bot_check(logins:)
      raise ArgumentError, "Batch size #{logins.size} exceeds max #{MAX_BATCH_SIZE}" if logins.size > MAX_BATCH_SIZE

      operations = logins.map { |login| { query: QUERIES[:bot_check], variables: { login: login } } }
      results = execute_batch(operations)

      results.map { |r| parse_user_profile(r&.dig("data", "user")) }
    end

    # FR-003: Channel viewer list (CommunityTab) — may require integrity token
    def community_tab(channel_login:, first: 100, after: nil)
      return nil if channel_login.blank?

      variables = { login: channel_login, first: first }
      variables[:after] = after if after

      result = execute(QUERIES[:community_tab], variables)
      chatters = result&.dig("data", "channel", "chatters")
      return nil unless chatters

      {
        broadcasters: parse_chatter_list(chatters.dig("broadcasters")),
        moderators: parse_chatter_list(chatters.dig("moderators")),
        vips: parse_chatter_list(chatters.dig("vips")),
        viewers: parse_chatter_list(chatters.dig("viewers")),
        count: chatters["count"]
      }
    end

    # FR-004: Chatters count — may require integrity token
    def channel_chatters_count(channel_login:)
      return nil if channel_login.blank?

      result = execute(QUERIES[:chatters_count], { login: channel_login })
      result&.dig("data", "channel", "chatters", "count")
    end

    # FR-005: Realtime viewer count
    def view_count(channel_login:)
      return nil if channel_login.blank?

      result = execute(QUERIES[:view_count], { login: channel_login })
      result&.dig("data", "user", "stream", "viewersCount")
    end

    # FR-006: Stream metadata (title, game, tags, language)
    def stream_metadata(channel_login:)
      return nil if channel_login.blank?

      result = execute(QUERIES[:stream_metadata], { login: channel_login })
      user = result&.dig("data", "user")
      return nil unless user

      stream = user["stream"]
      settings = user["broadcastSettings"]

      {
        id: stream&.dig("id"),
        title: settings&.dig("title"),
        game_name: settings&.dig("game", "name"),
        game_id: settings&.dig("game", "id"),
        started_at: stream&.dig("createdAt"),
        viewers_count: stream&.dig("viewersCount"),
        tags: stream&.dig("freeformTags")&.map { |t| t["name"] },
        language: settings&.dig("language"),
        type: stream&.dig("type")
      }
    end

    # FR-007: Chat room state (for Channel Protection Score)
    def chat_room_state(channel_login:)
      return nil if channel_login.blank?

      result = execute(QUERIES[:chat_room_state], { login: channel_login })
      settings = result&.dig("data", "user", "chatSettings")
      return nil unless settings

      {
        followers_only_duration_minutes: settings["followersOnlyDurationMinutes"],
        slow_mode_duration_seconds: settings["slowModeDurationSeconds"],
        emote_only_mode: settings["isEmoteOnlyModeEnabled"],
        block_links: settings["blockLinks"],
        chat_delay_ms: settings["chatDelayMs"],
        require_verified_account: settings["requireVerifiedAccount"]
      }
    end

    # FR-008: Viewer card (profile in channel context)
    def viewer_card(target_login:)
      return nil if target_login.blank?

      result = execute(QUERIES[:viewer_card], { login: target_login })
      parse_user_profile(result&.dig("data", "user"))
    end

    # FR-009: Channel about panel
    def channel_about(channel_login:)
      return nil if channel_login.blank?

      result = execute(QUERIES[:channel_about], { login: channel_login })
      user = result&.dig("data", "user")
      return nil unless user

      {
        id: user["id"],
        display_name: user["displayName"],
        description: user["description"],
        primary_color_hex: user["primaryColorHex"],
        profile_image_url: user["profileImageURL"],
        social_medias: user.dig("channel", "socialMedias")&.map do |sm|
          { name: sm["name"], title: sm["title"], url: sm["url"] }
        end
      }
    end

    # FR-014: User following list (for follow-bot detection)
    def user_following(login:, first: 20, after: nil)
      return nil if login.blank?

      variables = { login: login, first: first }
      variables[:after] = after if after

      result = execute(QUERIES[:user_following], variables)
      follows = result&.dig("data", "user", "follows")
      return nil unless follows

      {
        total_count: follows["totalCount"],
        follows: follows["edges"]&.map do |edge|
          {
            login: edge.dig("node", "login"),
            followed_at: edge["cursor"]
          }
        end || [],
        has_next_page: follows.dig("pageInfo", "hasNextPage"),
        cursor: follows.dig("pageInfo", "endCursor") || follows["edges"]&.last&.dig("cursor")
      }
    end

    # FR-015: Channel leaderboards (bits/gift sub leaders)
    def channel_leaderboards(channel_login:)
      return nil if channel_login.blank?

      result = execute(QUERIES[:channel_leaderboards], { login: channel_login })
      user = result&.dig("data", "user")
      return nil unless user

      {
        bits_leaders: user.dig("channel", "leaderboards", "bitsLeaderboard")&.map do |entry|
          { login: entry.dig("node", "login"), score: entry["score"] }
        end || [],
        gift_sub_leaders: user.dig("channel", "leaderboards", "giftSubLeaderboard")&.map do |entry|
          { login: entry.dig("node", "login"), total_gifts: entry["score"] }
        end || []
      }
    end

    # FR-016: Active moderators list
    def active_mods(channel_login:)
      return nil if channel_login.blank?

      result = execute(QUERIES[:active_mods], { login: channel_login })
      mods = result&.dig("data", "user", "mods", "edges")
      return [] unless mods

      mods.map { |edge| edge.dig("node", "login") }.compact
    end

    # FR-017: Top live streams (discovery)
    def top_streams(first: 20, game_id: nil)
      variables = { first: first }
      variables[:gameID] = game_id if game_id

      result = execute(QUERIES[:top_streams], variables)
      edges = result&.dig("data", "streams", "edges")
      return [] unless edges

      edges.map do |edge|
        node = edge["node"]
        {
          login: node.dig("broadcaster", "login"),
          display_name: node.dig("broadcaster", "displayName"),
          viewers_count: node["viewersCount"],
          game_name: node.dig("game", "name"),
          title: node["title"],
          started_at: node["createdAt"]
        }
      end
    end

    # Generic batch: send array of {query:, variables:} in one POST
    def batch(operations)
      raise ArgumentError, "Batch size #{operations.size} exceeds max #{MAX_BATCH_SIZE}" if operations.size > MAX_BATCH_SIZE

      execute_batch(operations)
    end

    private

    # === HTTP ===

    def execute(query, variables = {}, retries: 0)
      body = { query: query, variables: variables }
      response = http_client.post(GQL_URL, json: body)

      handle_response(response, query, variables, retries)
    rescue HTTP::TimeoutError => e
      Rails.logger.error("Twitch GQL timeout: #{e.message}")
      nil
    rescue HTTP::ConnectionError => e
      Rails.logger.error("Twitch GQL connection error: #{e.message}")
      nil
    end

    def execute_batch(operations, retries: 0)
      body = operations.map { |op| { query: op[:query], variables: op[:variables] || {} } }
      response = http_client.post(GQL_URL, json: body)

      case response.status.to_i
      when 200
        parse_batch_response(response)
      when 429
        handle_rate_limit(response, retries) { execute_batch(operations, retries: retries + 1) }
      when 500, 502, 503
        handle_server_error(response, retries) { execute_batch(operations, retries: retries + 1) }
      else
        Rails.logger.error("Twitch GQL batch error #{response.status}: #{response.body.to_s.truncate(200)}")
        Array.new(operations.size)
      end
    rescue HTTP::TimeoutError => e
      Rails.logger.error("Twitch GQL batch timeout: #{e.message}")
      Array.new(operations.size)
    rescue HTTP::ConnectionError => e
      Rails.logger.error("Twitch GQL batch connection error: #{e.message}")
      Array.new(operations.size)
    end

    def handle_response(response, query, variables, retries)
      case response.status.to_i
      when 200
        parse_single_response(response)
      when 429
        handle_rate_limit(response, retries) { execute(query, variables, retries: retries + 1) }
      when 500, 502, 503
        handle_server_error(response, retries) { execute(query, variables, retries: retries + 1) }
      else
        Rails.logger.error("Twitch GQL error #{response.status}: #{response.body.to_s.truncate(200)}")
        nil
      end
    end

    def http_client
      HTTP.timeout(REQUEST_TIMEOUT).headers(
        "Client-ID" => @client_id,
        "Content-Type" => "application/json",
        "User-Agent" => USER_AGENT
      )
    end

    # === Response parsing ===

    def parse_single_response(response)
      data = JSON.parse(response.body.to_s)

      if data["errors"]&.any?
        Rails.logger.error("Twitch GQL errors: #{data["errors"].map { |e| e["message"] }.join(", ").truncate(200)}")
      end

      data
    rescue JSON::ParserError => e
      Rails.logger.error("Twitch GQL JSON parse error: #{e.message}")
      nil
    end

    def parse_batch_response(response)
      data = JSON.parse(response.body.to_s)

      unless data.is_a?(Array)
        Rails.logger.error("Twitch GQL batch: expected Array, got #{data.class}")
        return []
      end

      data.map do |item|
        if item["errors"]&.any?
          Rails.logger.warn("Twitch GQL batch item error: #{item["errors"].map { |e| e["message"] }.join(", ").truncate(200)}")
        end
        item
      end
    rescue JSON::ParserError => e
      Rails.logger.error("Twitch GQL batch JSON parse error: #{e.message}")
      []
    end

    def parse_user_profile(user)
      return nil unless user

      {
        id: user["id"],
        login: user["login"],
        display_name: user["displayName"],
        created_at: user["createdAt"],
        description: user["description"],
        profile_view_count: user["profileViewCount"],
        profile_image_url: user["profileImageURL"],
        chat_color: user["chatColor"],
        is_partner: user.dig("roles", "isPartner"),
        is_affiliate: user.dig("roles", "isAffiliate"),
        followers_count: user.dig("followers", "totalCount"),
        follows_count: user.dig("follows", "totalCount"),
        last_broadcast: user["lastBroadcast"] && {
          started_at: user.dig("lastBroadcast", "startedAt"),
          title: user.dig("lastBroadcast", "title"),
          game_name: user.dig("lastBroadcast", "game", "name")
        },
        videos_count: user.dig("videos", "totalCount"),
        stream: user["stream"] && {
          id: user.dig("stream", "id"),
          viewers_count: user.dig("stream", "viewersCount"),
          game_name: user.dig("stream", "game", "name"),
          type: user.dig("stream", "type"),
          created_at: user.dig("stream", "createdAt")
        }
      }
    end

    def parse_chatter_list(list)
      return [] unless list.is_a?(Array)

      list.map { |u| u["login"] }.compact
    end

    # === Error handling ===

    def handle_rate_limit(response, retries, &retry_block)
      if retries >= MAX_RETRIES
        Rails.logger.error("Twitch GQL rate limit exhausted after #{MAX_RETRIES} retries")
        return nil
      end

      wait = BACKOFF_BASE * (2**retries)
      Rails.logger.warn("Twitch GQL 429: waiting #{wait}s (retry #{retries + 1}/#{MAX_RETRIES})")
      sleep(wait)
      retry_block.call
    end

    def handle_server_error(response, retries, &retry_block)
      if retries >= MAX_RETRIES
        Rails.logger.error("Twitch GQL #{response.status}: exhausted after #{MAX_RETRIES} retries")
        return nil
      end

      wait = BACKOFF_BASE * (2**retries)
      Rails.logger.warn("Twitch GQL #{response.status}: retry #{retries + 1}/#{MAX_RETRIES} in #{wait}s")
      sleep(wait)
      retry_block.call
    end

    # === GQL Queries (inline, not SHA256 hashes — SRS BR-008) ===
    # Verified against real Twitch GQL API on 2026-03-28

    QUERIES = {
      bot_check: <<~GQL.squish,
        query BotCheck($login: String!) {
          user(login: $login) {
            id login displayName createdAt description
            profileViewCount profileImageURL(width: 70)
            chatColor
            roles { isPartner isAffiliate }
            followers { totalCount }
            follows { totalCount }
            lastBroadcast { startedAt title game { name } }
            videos { totalCount }
            stream { id viewersCount game { name } type createdAt }
          }
        }
      GQL

      community_tab: <<~GQL.squish,
        query CommunityTab($login: String!, $first: Int!, $after: String) {
          channel(name: $login) {
            chatters {
              broadcasters { login }
              moderators { login }
              vips { login }
              viewers { login }
              count
            }
          }
        }
      GQL

      chatters_count: <<~GQL.squish,
        query GetChattersCount($login: String!) {
          channel(name: $login) {
            chatters { count }
          }
        }
      GQL

      view_count: <<~GQL.squish,
        query UseViewCount($login: String!) {
          user(login: $login) {
            stream { id viewersCount }
          }
        }
      GQL

      stream_metadata: <<~GQL.squish,
        query StreamMetadata($login: String!) {
          user(login: $login) {
            stream {
              id viewersCount type createdAt
              game { id name }
              freeformTags { name }
            }
            broadcastSettings {
              title language
              game { id name }
            }
          }
        }
      GQL

      chat_room_state: <<~GQL.squish,
        query ChatRoomState($login: String!) {
          user(login: $login) {
            chatSettings {
              followersOnlyDurationMinutes
              slowModeDurationSeconds
              isEmoteOnlyModeEnabled
              blockLinks
              chatDelayMs
              requireVerifiedAccount
            }
          }
        }
      GQL

      viewer_card: <<~GQL.squish,
        query ViewerCard($login: String!) {
          user(login: $login) {
            id login displayName createdAt description
            profileViewCount profileImageURL(width: 70)
            chatColor
            roles { isPartner isAffiliate }
            followers { totalCount }
            follows { totalCount }
            lastBroadcast { startedAt title game { name } }
            videos { totalCount }
            stream { id viewersCount game { name } type createdAt }
          }
        }
      GQL

      channel_about: <<~GQL.squish,
        query ChannelAbout($login: String!) {
          user(login: $login) {
            id displayName description primaryColorHex
            profileImageURL(width: 300)
            channel {
              socialMedias { name title url }
            }
          }
        }
      GQL

      user_following: <<~GQL.squish,
        query UserFollowing($login: String!, $first: Int!, $after: String) {
          user(login: $login) {
            follows(first: $first, after: $after) {
              totalCount
              edges {
                cursor
                node { login }
              }
              pageInfo { hasNextPage endCursor }
            }
          }
        }
      GQL

      channel_leaderboards: <<~GQL.squish,
        query ChannelLeaderboards($login: String!) {
          user(login: $login) {
            channel {
              leaderboards {
                bitsLeaderboard { node { login } score }
                giftSubLeaderboard { node { login } score }
              }
            }
          }
        }
      GQL

      active_mods: <<~GQL.squish,
        query ActiveMods($login: String!) {
          user(login: $login) {
            mods(first: 100) {
              edges { node { login } }
            }
          }
        }
      GQL

      top_streams: <<~GQL.squish
        query TopStreams($first: Int!, $gameID: ID) {
          streams(first: $first, options: { gameID: $gameID }) {
            edges {
              node {
                broadcaster { login displayName }
                viewersCount title createdAt
                game { name }
              }
            }
          }
        }
      GQL
    }.freeze
  end
end
