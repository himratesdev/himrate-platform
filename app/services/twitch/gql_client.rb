# frozen_string_literal: true

# TASK-022 + BUG-251.30: Twitch GQL Client.
# POST requests to gql.twitch.tv/gql with Android Client-ID — bypasses Kasada KPSDK integrity
# check entirely. ALL operations (incl. previously "integrity-protected" chatters / socialMedias /
# hasPrime/hasTurbo) work server-side. Verified live 2026-05-29 on justcooman: same persisted
# hash returned `failed integrity check` under web Client-ID and full chatters list under Android.
# Validated by ViewerMetrics extension (Chrome Web Store deployment) which uses the identical
# Android Client-ID + inline-query strategy.
#
# Research references:
# - `bft/_research/twitch-gql-research-himrate.md` (GQL hash catalog + Kasada analysis)
# - `_tasks/TASK-096-product-philosophy-shift/findings-40-deep-dive.md` Wave-3 Finding #1
#   (Android Client-ID bypass first verified 2026-05-06; propagation deferred 23 days — RC-8)
# - `_research/viewermetrics-re/viewermetrics-0.9.951/background/api-manager.js`
#   (single-header `Client-Id: kd1unb4b3q4t58fwlpcbzcbnm76a8fp`, no Client-Integrity)
#
# IMPORTANT: Call from Sidekiq workers only (not controllers).
# sleep() in retry handlers blocks the thread — unacceptable in web request cycle.

module Twitch
  class GqlClient
    GQL_URL = "https://gql.twitch.tv/gql"
    # Android Client-ID — bypasses Kasada KPSDK integrity (was: web Client-ID kimne78kx3ncx6brgo4mv6wki5h1ko,
    # integrity-gated; community_tab/socialMedias/hasPrime/etc. returned `failed integrity check`).
    # ENV override preserved for emergency rollback or testing alternate clients.
    DEFAULT_CLIENT_ID = "kd1unb4b3q4t58fwlpcbzcbnm76a8fp"
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

    # FR-003: Channel viewer list (CommunityTab). Works server-side via Android Client-ID
    # (BUG-251.30 verified 2026-05-29). Returns role-bucketed registered users present in chat
    # (broadcasters, moderators, vips, staff, viewers + total count). NOTE: Twitch caps the
    # `viewers` array at 100 entries per response on big channels (G-3 gap → BUG-251.31).
    def community_tab(channel_login:)
      return nil if channel_login.blank?

      result = execute(QUERIES[:community_tab], { login: channel_login })
      chatters = result&.dig("data", "channel", "chatters")
      return nil unless chatters

      broadcasters = parse_chatter_list(chatters.dig("broadcasters"))
      moderators = parse_chatter_list(chatters.dig("moderators"))
      vips = parse_chatter_list(chatters.dig("vips"))
      staff = parse_chatter_list(chatters.dig("staff"))
      viewers = parse_chatter_list(chatters.dig("viewers"))

      sum_present = broadcasters.size + moderators.size + vips.size + staff.size + viewers.size

      {
        broadcasters: broadcasters,
        moderators: moderators,
        vips: vips,
        staff: staff,
        viewers: viewers,
        count: chatters["count"],
        # BUG-251.30: total registered users present in chat. CR-iter2 N3 — prefer Twitch's
        # authoritative `chatters.count` (uncapped) over the sum of role arrays (capped at the
        # 100-entry viewers[] ceiling on big channels). Falls back to sum only when count is
        # absent. Keeps non-worker callers consistent with the worker's calibration baseline.
        total_present: chatters["count"]&.to_i || sum_present,
        all_logins: broadcasters + moderators + vips + staff + viewers
      }
    end

    # FR-004: Chatters count (registered chat-connected total). Works server-side via Android
    # Client-ID (BUG-251.30 verified 2026-05-29 — was previously integrity-gated under web ID).
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

    # BUG-110-B (TASK-110 FR-013): resolve downloadable clip mp4 URL via GQL.
    # Returns signed sourceURL (lowest quality — audio identical across qualities,
    # minimizes download для STT) OR nil если clip private/deleted/no qualities.
    # @param slug [String] Twitch clip slug (== Helix clip id)
    def clip_video_url(slug:)
      return nil if slug.blank?

      result = execute(QUERIES[:clip_video_url], { "slug" => slug })
      clip = result&.dig("data", "clip")
      return nil if clip.nil?

      qualities = clip["videoQualities"]
      return nil if qualities.blank?

      token = clip.dig("playbackAccessToken", "value")
      sig = clip.dig("playbackAccessToken", "signature")
      # Lowest quality (audio identical, smallest download). qualities desc by quality.
      source = qualities.last["sourceURL"]
      return nil if source.blank?

      return source if token.blank? || sig.blank?

      "#{source}?sig=#{sig}&token=#{CGI.escape(token.to_s)}"
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

    # FR-007 + BUG-251.32: Chat room state (for Channel Protection Score).
    # Twitch removed `Channel.accountVerificationOptions` type entirely (verified live 2026-05-29
    # via introspection: "Cannot query field 'accountVerificationOptions' on type 'Channel'").
    # The previous query failed for every channel since the schema migration happened, leaving
    # ChannelProtectionConfig NULL → CPS signal returned `reason: no_config` perma-skip.
    # Updated query drops the dead subtype; `requireVerifiedAccount` on chatSettings consolidates
    # email/phone verification booleans into a single field. ChannelProtectionConfig retains
    # legacy columns as deprecated-but-readable (NULL for new rows; historical rows untouched).
    def chat_room_state(channel_login:)
      return nil if channel_login.blank?

      result = execute(QUERIES[:chat_room_state], { login: channel_login })
      settings = result&.dig("data", "user", "chatSettings")
      return nil unless settings

      {
        followers_only_duration_minutes: settings["followersOnlyDurationMinutes"],
        subscriber_only_mode: settings["isSubscribersOnlyModeEnabled"],
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

    # FR-015 + FR-023: Channel bits leaderboard (cheer.leaderboard)
    # Note: GQL BitsLeaderboardEntry has id+score+rank but NOT user login.
    # Login can be resolved via separate bot_check(id) if needed.
    def channel_leaderboards(channel_login:, first: 10)
      return nil if channel_login.blank?

      result = execute(QUERIES[:channel_leaderboards], { login: channel_login, first: first })
      entries = result&.dig("data", "user", "cheer", "leaderboard", "entries", "edges")
      return nil unless entries

      entries.map do |edge|
        node = edge["node"]
        { id: node["id"], score: node["score"], rank: node["rank"] }
      end
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

    # FR-007: Active prediction on channel
    def predictions(channel_login:)
      return nil if channel_login.blank?

      result = execute(QUERIES[:predictions], { login: channel_login })
      event = result&.dig("data", "channel", "activePredictionEvent")
      return nil unless event && event["status"] == "ACTIVE"

      {
        id: event["id"],
        title: event["title"],
        status: event["status"],
        total_users: event["outcomes"]&.sum { |o| o["totalUsers"].to_i } || 0,
        total_points: event["outcomes"]&.sum { |o| o["totalPoints"].to_i } || 0,
        outcomes: event["outcomes"]&.map { |o| { title: o["title"], total_users: o["totalUsers"], total_points: o["totalPoints"] } }
      }
    end

    # FR-007: Active poll on channel
    def polls(channel_login:)
      return nil if channel_login.blank?

      result = execute(QUERIES[:polls], { login: channel_login })
      poll = result&.dig("data", "channel", "currentPoll")
      return nil unless poll && poll["status"] == "ACTIVE"

      {
        id: poll["id"],
        title: poll["title"],
        total_voters: poll["totalVoters"].to_i,
        choices: poll["choices"]&.map { |c| { title: c["title"], total_votes: c["totalVotes"] } }
      }
    end

    # FR-008: Active hype train on channel
    def hype_train(channel_login:)
      return nil if channel_login.blank?

      result = execute(QUERIES[:hype_train], { login: channel_login })
      train = result&.dig("data", "channel", "hypeTrainExecution")
      return nil unless train

      {
        id: train["id"],
        level: train["level"].to_i,
        progress: train["progress"].to_i,
        goal: train["goal"].to_i,
        conductors_count: train["conductors"]&.size || 0,
        ends_at: train["endsAt"],
        started_at: train["startedAt"]
      }
    end

    # Generic batch: send array of {query:, variables:} in one POST
    def batch(operations)
      raise ArgumentError, "Batch size #{operations.size} exceeds max #{MAX_BATCH_SIZE}" if operations.size > MAX_BATCH_SIZE

      execute_batch(operations)
    end

    # TASK-113 Δ-1 Wave 1 (FR-016 source #2): batch persisted-query operations (operationName +
    # sha256Hash + variables). Reuses execute_batch_persisted shell с 429/5xx retry handling.
    # Each operation: { operationName:, sha256Hash:, variables: }. Returns array (parallel size +
    # nil for failed items per batch).
    def batch_persisted_queries(operations)
      raise ArgumentError, "Batch size #{operations.size} exceeds max #{MAX_BATCH_SIZE}" if operations.size > MAX_BATCH_SIZE

      execute_batch_persisted(operations)
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

    # TASK-113 Δ-1 Wave 1: persisted-query batch shell (operationName + sha256Hash + variables).
    # Same 429/5xx retry semantics as execute_batch. Returns parallel array (size = operations.size).
    def execute_batch_persisted(operations, retries: 0)
      body = operations.map do |op|
        {
          operationName: op[:operationName],
          variables: op[:variables] || {},
          extensions: { persistedQuery: { version: 1, sha256Hash: op[:sha256Hash] } }
        }
      end
      response = http_client.post(GQL_URL, json: body)

      case response.status.to_i
      when 200
        parse_batch_response(response)
      when 429
        handle_rate_limit(response, retries) { execute_batch_persisted(operations, retries: retries + 1) }
      when 500, 502, 503
        handle_server_error(response, retries) { execute_batch_persisted(operations, retries: retries + 1) }
      else
        Rails.logger.error("Twitch GQL persisted-batch error #{response.status}: #{response.body.to_s.truncate(200)}")
        Array.new(operations.size)
      end
    rescue HTTP::TimeoutError => e
      Rails.logger.error("Twitch GQL persisted-batch timeout: #{e.message}")
      Array.new(operations.size)
    rescue HTTP::ConnectionError => e
      Rails.logger.error("Twitch GQL persisted-batch connection error: #{e.message}")
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
      # Phase 2 G rescue audit M1: batch shape failure was logger-only — invisible
      # when Twitch ships GQL response contract change. Caller sees `[]` indistinguishable
      # from genuine empty batch. Capture so we get alerted on shape break, not on
      # transient errors (those are 4xx/5xx handled upstream — never reach here).
      Rails.logger.error("Twitch GQL batch JSON parse error: #{e.message}")
      if defined?(Sentry)
        Sentry.with_scope do |scope|
          scope.set_tags(twitch_gql_failure: "batch_json_parse")
          scope.set_fingerprint([ "twitch_gql_batch_json_parse" ])
          scope.set_context("response", { body_preview: response.body.to_s.truncate(500) })
          Sentry.capture_exception(e)
        end
      end
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
        has_clips: user.dig("clips", "edges")&.any? || false,
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
            profileImageURL(width: 70)
            chatColor
            roles { isPartner isAffiliate }
            followers { totalCount }
            follows { totalCount }
            lastBroadcast { startedAt title game { name } }
            videos { totalCount }
            clips(first: 1, criteria: { period: ALL_TIME }) { edges { node { id } } }
            stream { id viewersCount game { name } type createdAt }
          }
        }
      GQL

      community_tab: <<~GQL.squish,
        query CommunityTab($login: String!) {
          channel(name: $login) {
            chatters {
              broadcasters { login }
              moderators { login }
              vips { login }
              staff { login }
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

      # BUG-251.32: dropped dead `channel.accountVerificationOptions` block — Twitch removed
      # the subtype entirely. requireVerifiedAccount on chatSettings now consolidates
      # email/phone/min-age verification into one boolean.
      chat_room_state: <<~GQL.squish,
        query ChatRoomState($login: String!) {
          user(login: $login) {
            chatSettings {
              followersOnlyDurationMinutes
              isSubscribersOnlyModeEnabled
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
            profileImageURL(width: 70)
            chatColor
            roles { isPartner isAffiliate }
            followers { totalCount }
            follows { totalCount }
            lastBroadcast { startedAt title game { name } }
            videos { totalCount }
            clips(first: 1, criteria: { period: ALL_TIME }) { edges { node { id } } }
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
        query UserFollowing($login: String!, $first: Int!, $after: Cursor) {
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
        query ChannelLeaderboards($login: String!, $first: Int!) {
          user(login: $login) {
            cheer {
              leaderboard(first: $first) {
                entries {
                  edges {
                    node { id score rank }
                  }
                }
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

      predictions: <<~GQL.squish,
        query ChannelPredictions($login: String!) {
          channel(name: $login) {
            activePredictionEvent {
              id title status
              outcomes { id title totalPoints totalUsers }
            }
          }
        }
      GQL

      polls: <<~GQL.squish,
        query ChannelPolls($login: String!) {
          channel(name: $login) {
            currentPoll {
              id title status
              choices { id title totalVotes }
              totalVoters
            }
          }
        }
      GQL

      hype_train: <<~GQL.squish,
        query HypeTrain($login: String!) {
          channel(name: $login) {
            hypeTrainExecution {
              id level progress goal
              conductors { id participationType quantity }
              endsAt startedAt
            }
          }
        }
      GQL

      top_streams: <<~GQL.squish,
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

      # BUG-110-B (TASK-110 FR-013): clip downloadable video URL + playback access token.
      # Helix /clips НЕ отдаёт video URL; thumbnail derivation сломан для современных
      # twitch-video-assets CDN clips. GQL clip query (inline, DSV-verified 2026-05-20) →
      # videoQualities[].sourceURL + playbackAccessToken{signature,value}. Download =
      # sourceURL + ?sig=<signature>&token=<url-encoded value>.
      clip_video_url: <<~GQL.squish
        query ClipVideoURL($slug: ID!) {
          clip(slug: $slug) {
            playbackAccessToken(params: {platform: "web", playerBackend: "mediaplayer", playerType: "clips-download"}) {
              signature
              value
            }
            videoQualities { sourceURL quality frameRate }
          }
        }
      GQL
    }.freeze
  end
end
