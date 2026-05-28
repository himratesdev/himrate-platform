# frozen_string_literal: true

module Clickhouse
  # TASK-251.14d: ClickHouse-side equivalents of the 4 chat queries TrustIndex::ContextBuilder
  # currently runs against Postgres. Each method returns the SAME shape as its PG counterpart so the
  # downstream signal pipeline doesn't care which store served the read. Used by ContextBuilder when
  # the :chat_reads_clickhouse_dual_read flag (parity validation) OR :chat_reads_clickhouse flag
  # (CH-only flip) is ON.
  #
  # Window alignment (CR-198 Nit-2): the MVs aggregate at minute granularity (toStartOfMinute), so
  # PG and CH only stay in 0-divergence parity if both READ at minute-rounded boundaries.
  # ContextBuilder floors `since` to the minute before dispatch — the same floor is applied to the
  # PG path so dual-read compares apples-to-apples.
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
      rows.map { |r| { msg_count: r["c"].to_i, timestamp: Time.utc(*r["minute"].split(/[-:\s]/).map(&:to_i)) } }
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

    # Mirrors PG fetch_unique_chatters output: Integer count of distinct chatters in the last 60 min.
    def unique_chatters(stream)
      since_min = 60.minutes.ago.utc.strftime("%Y-%m-%d %H:%M:00")
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

    # Mirrors PG fetch_cross_channel output: { username => distinct_channel_count } over rolling 24h.
    # RAW scan (not an MV) so the 24h window is exact (0-divergence vs PG). uniqExact gives an exact
    # count (matches PG's COUNT(DISTINCT)). The ORDER BY username + LIMIT picks the same usernames as
    # the matching PG query so the result-set keys align in dual-read.
    def cross_channel(stream)
      username_rows = Clickhouse.client.select(<<~SQL)
        SELECT DISTINCT username
        FROM chat_messages
        WHERE stream_id = '#{stream.id}' AND msg_type = 'privmsg'
        ORDER BY username
        LIMIT #{CROSS_CHANNEL_CHATTER_LIMIT}
      SQL
      usernames = username_rows.map { |r| r["username"] }
      return {} if usernames.empty?

      quoted = usernames.map { |u| "'#{u.gsub("'", "''")}'" }.join(",")
      rows = Clickhouse.client.select(<<~SQL)
        SELECT username, uniqExact(channel_login) AS c
        FROM chat_messages
        WHERE username IN (#{quoted}) AND msg_type = 'privmsg'
          AND timestamp > now() - INTERVAL 24 HOUR
        GROUP BY username
      SQL
      rows.to_h { |r| [ r["username"], r["c"].to_i ] }
    rescue Clickhouse::Error => e
      Rails.logger.warn("Clickhouse::ChatQueries: cross_channel failed (#{e.class})")
      {}
    end
  end
end
