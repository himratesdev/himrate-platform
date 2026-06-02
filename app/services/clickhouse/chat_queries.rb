# frozen_string_literal: true

module Clickhouse
  # ClickHouse-side equivalents of the chat queries the platform runs (used directly by
  # TrustIndex::ContextBuilder + the 3 chat workers post-cutover; the dual-read scaffolding and
  # :chat_reads_clickhouse_dual_read / :chat_reads_clickhouse flags from TASK-251.14d are gone
  # along with the PG dispatch leaves — CH is the SoT). Each method returns the SAME shape as its
  # historical PG counterpart so the downstream signal/worker pipeline doesn't change.
  #
  # Window alignment (CR-198 Nit-2): the MVs aggregate at minute granularity (toStartOfMinute),
  # so ContextBuilder floors `since` to the minute at the call-site before invoking the MV-backed
  # methods. Raw-scan methods (cross_channel, chatter_cross_channel_counts) take the absolute
  # 24h cutoff with usec zeroed for second-resolution determinism.
  #
  # `cross_channel` reads RAW chat_messages (per SRS revision after the DSV — raw columnar scan = 30
  # ms, exact rolling-24h semantics) rather than an MV; the rolling window is what enables true
  # 0-divergence vs Postgres at the 1d flip. The username list is ORDER BY username so PG and CH
  # pick the same deterministic 500 (PG path was tweaked to match for parity).
  module ChatQueries
    CROSS_CHANNEL_CHATTER_LIMIT = 500

    module_function

    # Mirrors TrustIndex::ContextBuilder PG fetch_chat_rate output:
    #   [{ msg_count: Integer, timestamp: Time }, ...] sorted by timestamp asc.
    def chat_rate(stream, since)
      since_min = since.utc.strftime("%Y-%m-%d %H:%M:00")
      rows = Clickhouse.client.select(<<~SQL)
        SELECT toString(minute) AS minute, countMerge(msg_count) AS c
        FROM mv_stream_minute_target
        WHERE stream_id = '#{stream.id}' AND minute >= '#{since_min}'
        GROUP BY minute ORDER BY minute
      SQL
      # Parse the minute string explicitly as UTC: appending " UTC" forces Time.parse to interpret
      # the wall-clock as UTC instead of the process's local TZ (the CH server is UTC-pinned by
      # `<timezone>UTC</timezone>` in constrained.xml, so the raw string is always UTC). Tolerates
      # CH format drift (sub-second / future formatting changes) without the brittleness of the
      # split-by-delimiter approach. CR-206 Nit-5.
      rows.map { |r| { msg_count: r["c"].to_i, timestamp: Time.parse("#{r['minute']} UTC") } }
    rescue Clickhouse::Error => e
      Rails.logger.warn("Clickhouse::ChatQueries: chat_rate failed (#{e.class})")
      []
    end

    # Mirrors PG fetch_chat_username_counts output: { username => count } over the same window.
    def chat_username_counts(stream, since)
      since_min = since.utc.strftime("%Y-%m-%d %H:%M:00")
      rows = Clickhouse.client.select(<<~SQL)
        SELECT username, countMerge(msg_count) AS c
        FROM mv_stream_user_minute_target
        WHERE stream_id = '#{stream.id}' AND minute >= '#{since_min}'
        GROUP BY username
      SQL
      rows.to_h { |r| [ r["username"], r["c"].to_i ] }
    rescue Clickhouse::Error => e
      Rails.logger.warn("Clickhouse::ChatQueries: chat_username_counts failed (#{e.class})")
      {}
    end

    # Mirrors PG fetch_unique_chatters: Integer count of distinct chatters since the given cutoff
    # (caller passes an absolute timestamp — captured once by the dispatch wrapper so PG and CH
    # share the exact same window; CR-206 Should-1).
    def unique_chatters(stream, since)
      since_min = since.utc.strftime("%Y-%m-%d %H:%M:00")
      rows = Clickhouse.client.select(<<~SQL)
        SELECT uniqExactMerge(unique_chatters) AS u
        FROM mv_stream_minute_target
        WHERE stream_id = '#{stream.id}' AND minute >= '#{since_min}'
      SQL
      rows.first&.fetch("u", nil)&.to_i
    rescue Clickhouse::Error => e
      Rails.logger.warn("Clickhouse::ChatQueries: unique_chatters failed (#{e.class})")
      nil
    end

    # Mirrors PG fetch_cross_channel output: { username => distinct_channel_count } over the window
    # ending now and starting at the caller-supplied `since` (an absolute Time, captured once by the
    # dispatch wrapper — CR-206 Should-2: three independent `now()` references would drift across
    # the 24h edge). RAW scan (not an MV) so the window is exact (0-divergence vs PG); uniqExact
    # matches PG's COUNT(DISTINCT). ORDER BY username + LIMIT picks the same deterministic 500 as
    # the PG path.
    #
    # BUG-SCW-CROSS-CHANNEL (2026-06-02): kept as the fallback path when Flipper[:cross_channel_digest]
    # is OFF (or a deploy-rollback). The hot path is now ContextBuilder → CrossChannelDigest.bulk_lookup
    # (one PG SELECT instead of a 24h CH scan); see app/services/trust_index/context_builder.rb.
    def cross_channel(stream, since)
      since_ts = since.utc.strftime("%Y-%m-%d %H:%M:%S")
      usernames = stream_chatters(stream)
      return {} if usernames.empty?

      quoted = usernames.map { |u| "'#{escape_string_literal(u)}'" }.join(",")
      rows = Clickhouse.client.select(<<~SQL)
        SELECT username, uniqExact(channel_login) AS c
        FROM chat_messages
        WHERE username IN (#{quoted}) AND msg_type = 'privmsg'
          AND timestamp > toDateTime('#{since_ts}')
        GROUP BY username
      SQL
      rows.to_h { |r| [ r["username"], r["c"].to_i ] }
    rescue Clickhouse::Error => e
      Rails.logger.warn("Clickhouse::ChatQueries: cross_channel failed (#{e.class})")
      {}
    end

    # Pick the deterministic 500 usernames who posted in this stream (mirrors the q1 username
    # selection that `cross_channel` used to run inline). Extracted so the digest-backed path
    # (BUG-SCW-CROSS-CHANNEL) can share the same chatter set without re-running the join-style
    # second query — ContextBuilder calls this on the hot path and then looks up the count via
    # CrossChannelDigest.bulk_lookup.
    def stream_chatters(stream)
      rows = Clickhouse.client.select(<<~SQL)
        SELECT DISTINCT username
        FROM chat_messages
        WHERE stream_id = '#{stream.id}' AND msg_type = 'privmsg'
        ORDER BY username
        LIMIT #{CROSS_CHANNEL_CHATTER_LIMIT}
      SQL
      rows.map { |r| r["username"] }
    rescue Clickhouse::Error => e
      Rails.logger.warn("Clickhouse::ChatQueries: stream_chatters failed (#{e.class})")
      []
    end

    # ClickHouse string-literal escape: backslash first (CH single-quoted strings honor C-style
    # escapes), then single-quote. Block-form gsub avoids the gsub-replacement back-reference
    # interpretation that bites the naive `gsub('\\', '\\\\')` form. CR-206 Should-3.
    def escape_string_literal(value)
      value.gsub(/[\\']/) { |c| c == "\\" ? "\\\\" : "''" }
    end

    # ─── PR 1e-A migrations (BotScoringWorker / StreamMonitorWorker / ChatMessageWorker) ───
    # Mirrors of the per-stream chat queries the readers ran against Postgres before the CH cutover.
    # Each method returns the SAME shape as the PG equivalent it replaces.

    # CR-231 Nit-5: stream UUIDs come from PG (no live exploit), but consistency with the
    # escape_string_literal pattern used for usernames calls for a guard. Reject anything that
    # isn't UUID-shaped so a future caller can't sneak in arbitrary SQL via the interpolation.
    UUID_RE = /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i

    # CR-231 iter-2 N1: contract divergence — raises ArgumentError (bad input = caller bug,
    # don't silently return {} and pretend nothing happened) vs the sibling rescue Clickhouse::Error
    # log-and-return-{} (transient infra; analytics tolerates an empty window).
    def validate_stream_uuid!(sids)
      Array(sids).each do |sid|
        raise ArgumentError, "Clickhouse::ChatQueries: stream_id #{sid.inspect} is not a UUID" unless sid.to_s.match?(UUID_RE)
      end
    end

    # Mirrors BotScoringWorker#collect_chatters (PG):
    #   per-user max(user_type)/max(subscriber_status)/bool_or(returning_chatter)/bool_or(vip)/
    #   max(badge_info)/sum(bits_used)/count(*). PG `MAX(LowCardinality(String))` → CH `any()` on the
    #   skinny dimension columns (any sampled value is fine — the worker treats irc_tags as last-seen
    #   state, not a hard aggregate). PG `BOOL_OR` → CH `max(UInt8)` since the columns are UInt8 (0/1).
    # Returns Hash { username => { irc_tags: {...}, chat_stats: { message_count: n } } } — exact
    # caller-side shape so collect_chatters drops in as a pure swap.
    def chatter_aggregations(stream)
      validate_stream_uuid!(stream.id)
      rows = Clickhouse.client.select(<<~SQL)
        SELECT
          username,
          any(user_type)            AS user_type,
          any(subscriber_status)    AS subscriber_status,
          max(returning_chatter)    AS returning_chatter,
          max(vip)                  AS vip,
          any(badge_info)           AS badge_info,
          sum(bits_used)            AS bits_used,
          count()                   AS msg_count
        FROM chat_messages
        WHERE stream_id = '#{stream.id}' AND username != ''
        GROUP BY username
      SQL
      rows.to_h do |r|
        [ r["username"], {
            irc_tags: {
              user_type: r["user_type"],
              subscriber_status: r["subscriber_status"],
              returning_chatter: r["returning_chatter"].to_i == 1,
              vip: r["vip"].to_i == 1,
              badge_info: r["badge_info"],
              bits_used: r["bits_used"].to_i
            },
            chat_stats: { message_count: r["msg_count"].to_i }
          } ]
      end
    rescue Clickhouse::Error => e
      Rails.logger.warn("Clickhouse::ChatQueries: chatter_aggregations failed (#{e.class})")
      {}
    end

    # PR #259 (2026-06-02 perf-debt): consolidated raw-scan replacement for chatter_timestamps +
    # chatter_messages + chatter_emotes. Three separate full-scans of the same chat_messages
    # partition (one per column projection) collapse to a SINGLE scan with all four columns,
    # then split client-side. BSW post-stream-end scan time drops ~3× (3 scans @ ~800ms each
    # → 1 scan @ ~800ms; CH benchmark 2026-06-02 confirmed 549-2084ms per old call).
    #
    # Returns Hash { username => { timestamps: [Time], messages: [String], emote_strings: [String] } }
    # — exact superset of the per-method shapes the old three calls produced. Filters preserve the
    # old semantics: `message_text != ''` and `emotes != ''` filters happen Ruby-side after the
    # single scan so the consolidated query plan stays simple (one stream_id + msg_type predicate).
    def chatter_raw_data(stream)
      validate_stream_uuid!(stream.id)
      rows = Clickhouse.client.select(<<~SQL)
        SELECT username, timestamp, message_text, emotes
        FROM chat_messages
        WHERE stream_id = '#{stream.id}' AND msg_type = 'privmsg' AND username != ''
        ORDER BY username, timestamp
      SQL
      rows.group_by { |r| r["username"] }.transform_values do |group|
        {
          timestamps:    group.map { |r| Time.parse("#{r['timestamp']} UTC") },
          messages:      group.filter_map { |r| r["message_text"] unless r["message_text"].nil? || r["message_text"] == "" },
          emote_strings: group.filter_map { |r| r["emotes"] unless r["emotes"].nil? || r["emotes"] == "" }
        }
      end
    rescue Clickhouse::Error => e
      Rails.logger.warn("Clickhouse::ChatQueries: chatter_raw_data failed (#{e.class})")
      {}
    end

    # Mirrors BotScoringWorker#fetch_cross_channel_counts — { username => distinct_channel_count }
    # over the given window. Differs from ChatQueries.cross_channel above (which takes a stream and
    # picks 500 chatters itself) by accepting a pre-resolved usernames array.
    #
    # CR-231 S1: msg_type = 'privmsg' filter is INTENTIONAL post-cutover, NOT preserved from the
    # PG path. The pre-cutover PG implementation (BotScoringWorker#fetch_cross_channel_counts) had
    # no msg_type filter — that was incidentally broader (counted USERNOTICE / clearchat /
    # roomstate "presence" too). The correct semantic for "cross-channel **chat** presence" is
    # privmsg only — same restriction the sibling ContextBuilder#cross_channel already used. The
    # PG path being broader was an oversight; this PR aligns both call-sites on the right rule.
    def chatter_cross_channel_counts(usernames, since)
      return {} if usernames.empty?

      since_ts = since.utc.strftime("%Y-%m-%d %H:%M:%S")
      quoted = usernames.map { |u| "'#{escape_string_literal(u)}'" }.join(",")
      rows = Clickhouse.client.select(<<~SQL)
        SELECT username, uniqExact(channel_login) AS c
        FROM chat_messages
        WHERE username IN (#{quoted}) AND msg_type = 'privmsg'
          AND timestamp > toDateTime('#{since_ts}')
        GROUP BY username
      SQL
      rows.to_h { |r| [ r["username"], r["c"].to_i ] }
    rescue Clickhouse::Error => e
      Rails.logger.warn("Clickhouse::ChatQueries: chatter_cross_channel_counts failed (#{e.class})")
      {}
    end

    # ─── Raid detection migration (RaidDetectionWorker) ─────────────────────────
    # RaidDetectionWorker classifies IRC USERNOTICE raid messages. Post PR #231 the
    # writer stopped dual-writing to PG, so raid USERNOTICEs now land ONLY in CH — these
    # CH-side mirrors keep signal #9 alive.

    # Mirrors RaidDetectionWorker#unprocessed_raids (PG):
    # SELECT raid USERNOTICEs in [since, until_] with NOT NULL stream_id+twitch_msg_id,
    # ordered chronologically, capped. Each row carries the fields the classifier needs
    # (raid tag bag + raid timestamp + linked stream). PG's NOT EXISTS against
    # raid_attributions can't be done here (CH ↔ PG is cross-DB), so the caller filters
    # already-processed twitch_msg_ids in Ruby after the fetch.
    #
    # raw_tags lives in CH as a JSON String (ZSTD-compressed), unlike PG's jsonb Hash —
    # we decode it here so the caller sees the same Hash shape PG returned. Empty/missing
    # tags → empty Hash (matches PG ChatMessage#raw_tags default).
    def raid_messages_pending(since:, until_:, limit:)
      since_ts  = since.utc.strftime("%Y-%m-%d %H:%M:%S.%3N")
      until_ts  = until_.utc.strftime("%Y-%m-%d %H:%M:%S.%3N")
      rows = Clickhouse.client.select(<<~SQL)
        SELECT stream_id, timestamp, username, twitch_msg_id, raw_tags
        FROM chat_messages
        WHERE msg_type = 'raid'
          AND stream_id IS NOT NULL
          AND twitch_msg_id != ''
          AND timestamp >= toDateTime64('#{since_ts}', 3)
          AND timestamp <= toDateTime64('#{until_ts}', 3)
        ORDER BY timestamp
        LIMIT #{limit.to_i}
      SQL
      rows.map do |r|
        {
          stream_id:     r["stream_id"],
          timestamp:     Time.parse("#{r['timestamp']} UTC"),
          username:      r["username"],
          twitch_msg_id: r["twitch_msg_id"],
          raw_tags:      parse_raw_tags(r["raw_tags"])
        }
      end
    rescue Clickhouse::Error => e
      Rails.logger.warn("Clickhouse::ChatQueries: raid_messages_pending failed (#{e.class})")
      []
    end

    # Mirrors RaidDetectionWorker#privmsg_logins (PG):
    # SELECT DISTINCT username FROM chat_messages WHERE stream_id=? AND msg_type='privmsg'
    #   AND timestamp BETWEEN from..to.
    # Returns Array<String> (matches the PG `.pluck(:username)` shape — caller does set ops).
    def privmsg_logins(stream, from:, to:)
      validate_stream_uuid!(stream.id)
      from_ts = from.utc.strftime("%Y-%m-%d %H:%M:%S.%3N")
      to_ts   = to.utc.strftime("%Y-%m-%d %H:%M:%S.%3N")
      rows = Clickhouse.client.select(<<~SQL)
        SELECT DISTINCT username
        FROM chat_messages
        WHERE stream_id = '#{stream.id}'
          AND msg_type = 'privmsg'
          AND username != ''
          AND timestamp >= toDateTime64('#{from_ts}', 3)
          AND timestamp <  toDateTime64('#{to_ts}', 3)
      SQL
      rows.map { |r| r["username"] }
    rescue Clickhouse::Error => e
      Rails.logger.warn("Clickhouse::ChatQueries: privmsg_logins failed (#{e.class})")
      []
    end

    # CH stores raw_tags as JSON String (ZSTD-compressed). PG had it as jsonb (Hash). Tolerate
    # nil / blank / malformed JSON — return {} so callers can index into the Hash without nil-guards.
    # CR-234 Nit-1: type-guard the JSON.parse result — the writer always emits a Hash, but `parse`
    # accepts any valid JSON (arrays / scalars), and downstream code does `tags["msg-id"]` which
    # would TypeError on a parsed array. Return {} so the per-raid rescue isn't load-bearing for
    # this trivially-checkable shape contract.
    def parse_raw_tags(value)
      return {} if value.nil? || value.to_s.empty?

      parsed = JSON.parse(value)
      parsed.is_a?(Hash) ? parsed : {}
    rescue JSON::ParserError
      {}
    end
    private_class_method :parse_raw_tags

    # ─── Chatter profile refresh migration (ChatterProfileRefreshWorker) ────────
    # Mirrors ChatterProfileRefreshWorker#logins_to_enrich raw input: DISTINCT non-empty usernames
    # that chatted (any msg_type — privmsg / RESUB / etc count as "active") since the given cutoff,
    # capped at `limit`. Caller does the cross-DB NOT EXISTS filter against PG chatter_profiles in
    # Ruby (the CH side oversamples because the freshness filter rejects most entries in steady
    # state). Order is implementation-defined; caller's set-difference doesn't care.
    def distinct_active_chatters(since:, limit:)
      since_ts = since.utc.strftime("%Y-%m-%d %H:%M:%S.%3N")
      rows = Clickhouse.client.select(<<~SQL)
        SELECT DISTINCT username
        FROM chat_messages
        WHERE timestamp > toDateTime64('#{since_ts}', 3)
          AND username != ''
        LIMIT #{limit.to_i}
      SQL
      rows.map { |r| r["username"] }
    rescue Clickhouse::Error => e
      Rails.logger.warn("Clickhouse::ChatQueries: distinct_active_chatters failed (#{e.class})")
      []
    end

    # ─── ML feature aggregations (Ml::Features::ChatSignals, PR3) ──────────────
    # Single multi-aggregate over the stream's chat history (msg_type='privmsg') returning
    # everything `Ml::Features::ChatSignals` needs to derive the 7 BFT 15_ML-Pipeline.md §3.2
    # chat features. One query, columnar scan; for typical per-stream chat sizes (≤200k
    # privmsgs) CH returns in milliseconds.
    #
    # Returns Hash:
    #   - :total_messages (Integer) — total privmsg count
    #   - :unique_messages (Integer) — distinct message_text count
    #   - :unique_chatters (Integer) — distinct username count
    #   - :messages_with_emotes (Integer) — count where emotes != ''
    #   - :single_message_chatters (Integer) — chatters posting exactly 1 message
    #   - :message_entropy_bits (Float|nil) — Shannon entropy of message_text distribution
    #   - :mean_inter_msg_sec (Float|nil) — mean gap between consecutive privmsgs
    #   - :std_inter_msg_sec (Float|nil) — stddev of consecutive privmsg gaps
    # All nil-safe; on CH error returns empty Hash so caller treats as insufficient data.
    def chat_feature_aggregates(stream)
      validate_stream_uuid!(stream.id)

      # 1. Single SELECT covering counts + entropy.
      # CR-250 N2: `total` CTE precomputes count() once instead of inlining `(SELECT count() FROM stream_msgs)`
      # 3 times inside the entropy aggregate. Readability + planner determinism (CH may or may not CSE
      # subqueries depending on version); for typical ≤200k privmsg scans the perf delta is negligible
      # but the explicit CTE removes the question.
      agg = Clickhouse.client.select(<<~SQL).first
        WITH stream_msgs AS (
          SELECT message_text, username, emotes
          FROM chat_messages
          WHERE stream_id = '#{stream.id}' AND msg_type = 'privmsg' AND username != ''
        ),
        total AS (SELECT count() AS n FROM stream_msgs),
        text_freq AS (
          SELECT count() AS c FROM stream_msgs GROUP BY message_text
        )
        SELECT
          (SELECT n                        FROM total)                                    AS total_messages,
          (SELECT uniqExact(message_text)  FROM stream_msgs)                              AS unique_messages,
          (SELECT uniqExact(username)      FROM stream_msgs)                              AS unique_chatters,
          (SELECT countIf(emotes != '')    FROM stream_msgs)                              AS messages_with_emotes,
          (SELECT -sum((c / (SELECT n FROM total)) * log2(c / (SELECT n FROM total)))
             FROM text_freq)                                                              AS message_entropy_bits
      SQL

      # 2. Single-message chatters (separate because nested aggregate against subquery is heavy).
      single_row = Clickhouse.client.select(<<~SQL).first
        SELECT count() AS single_message_chatters FROM (
          SELECT username FROM chat_messages
          WHERE stream_id = '#{stream.id}' AND msg_type = 'privmsg' AND username != ''
          GROUP BY username HAVING count() = 1
        )
      SQL

      # 3. Inter-message intervals — use window function over timestamps.
      # Cast to Float64 for sub-second precision (DateTime64 -> seconds since epoch).
      timing = Clickhouse.client.select(<<~SQL).first
        SELECT
          avg(diff_sec)        AS mean_inter_msg_sec,
          stddevSamp(diff_sec) AS std_inter_msg_sec
        FROM (
          SELECT
            (toUnixTimestamp64Milli(timestamp) - toUnixTimestamp64Milli(lagInFrame(timestamp, 1) OVER (ORDER BY timestamp))) / 1000.0 AS diff_sec
          FROM chat_messages
          WHERE stream_id = '#{stream.id}' AND msg_type = 'privmsg'
        )
        WHERE diff_sec IS NOT NULL AND diff_sec > 0
      SQL

      {
        total_messages:           (agg && agg["total_messages"]).to_i,
        unique_messages:          (agg && agg["unique_messages"]).to_i,
        unique_chatters:          (agg && agg["unique_chatters"]).to_i,
        messages_with_emotes:     (agg && agg["messages_with_emotes"]).to_i,
        message_entropy_bits:     agg && agg["message_entropy_bits"]&.to_f,
        single_message_chatters:  (single_row && single_row["single_message_chatters"]).to_i,
        mean_inter_msg_sec:       timing && timing["mean_inter_msg_sec"]&.to_f,
        std_inter_msg_sec:        timing && timing["std_inter_msg_sec"]&.to_f
      }
    rescue Clickhouse::Error => e
      Rails.logger.warn("Clickhouse::ChatQueries: chat_feature_aggregates failed (#{e.class})")
      {}
    end

    # ─── ML stability aggregations (Ml::Features::StabilitySignals, PR6) ──────
    # Batched per-stream total privmsg count, used to derive chat-rate CV across N streams.
    # No time-since filter — каждая stream сама определяет свой window via `started_at..ended_at`,
    # CH `chat_messages.stream_id` уже фильтрует to the stream lifecycle. Returns
    # Hash { stream_id => total_privmsgs }; streams без privmsgs absent from the Hash so caller
    # can use `.to_i` for 0-default safely.
    def privmsg_counts_for_streams(stream_ids)
      return {} if stream_ids.empty?

      validate_stream_uuid!(stream_ids)
      quoted = stream_ids.map { |sid| "'#{sid}'" }.join(",")
      rows = Clickhouse.client.select(<<~SQL)
        SELECT stream_id, count() AS total
        FROM chat_messages
        WHERE stream_id IN (#{quoted}) AND msg_type = 'privmsg' AND username != ''
        GROUP BY stream_id
      SQL
      rows.to_h { |r| [ r["stream_id"], r["total"].to_i ] }
    rescue Clickhouse::Error => e
      Rails.logger.warn("Clickhouse::ChatQueries: privmsg_counts_for_streams failed (#{e.class})")
      {}
    end

    # Mirrors StreamMonitorWorker#fetch_chat_activity — batched per-stream chat activity over the
    # given window. Returns Hash { stream_id => { unique: n, total: n } } for the streams that had
    # any privmsg in the window (others absent from the Hash, matching the PG groupby behaviour).
    def chat_activity_batch(stream_ids, since)
      return {} if stream_ids.empty?

      # CR-231 Nit-5: guard stream_ids — they're UUIDs from PG so no live exploit, but the SQL is
      # interpolated and the username path next door uses escape_string_literal. Consistency.
      validate_stream_uuid!(stream_ids)

      since_ts = since.utc.strftime("%Y-%m-%d %H:%M:%S")
      quoted = stream_ids.map { |sid| "'#{sid}'" }.join(",")
      rows = Clickhouse.client.select(<<~SQL)
        SELECT stream_id, count() AS total, uniqExact(username) AS unique_n
        FROM chat_messages
        WHERE stream_id IN (#{quoted}) AND msg_type = 'privmsg'
          AND timestamp > toDateTime('#{since_ts}')
        GROUP BY stream_id
      SQL
      rows.to_h { |r| [ r["stream_id"], { unique: r["unique_n"].to_i, total: r["total"].to_i } ] }
    rescue Clickhouse::Error => e
      Rails.logger.warn("Clickhouse::ChatQueries: chat_activity_batch failed (#{e.class})")
      {}
    end
  end
end
