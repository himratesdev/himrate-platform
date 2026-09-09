# frozen_string_literal: true

module Clickhouse
  # ClickHouse side of the coordination layer (see db/clickhouse/007_coordination_events.sql).
  #
  # Three queries, in the order the pipeline uses them:
  #   1. collect_hour!  — one hour of chat → `coordination_events` (INSERT..SELECT, server-side).
  #   2. accounts       — the co-firing population over a multi-day window, with its channel sets.
  #   3. channel_pairs  — those sets folded into channel↔channel edges (the group substrate).
  #
  # Reads `chat_messages` ONLY (monitored archive). The farm capture never enters this path — a
  # coordination finding is an accusation and the farm firewall forbids it (004/005 headers).
  module CoordinationQueries
    # An "event" = the account posted in >= MIN_CHANNELS distinct channels inside a
    # WINDOW_SECONDS bucket. Same definition and the same two-phase offset grid as the T1-057
    # signal (ChatQueries#temporal_co_occurrence) so the two agree by construction; the only
    # difference is that this one KEEPS the channel identities.
    WINDOW_SECONDS = 5
    MIN_CHANNELS = 3

    # Read-window guards. `mc <= DEDICATED_MAX_CONCURRENT` keeps the dedicated-pool signature
    # (verified on live data: 2137 of 2140 co-firing accounts sit at 3..8) and drops roaming
    # utility/spam accounts, which is what FULLCHAIN M3.1 established for c_hard_abs.
    # `MAX_CHANNELS_PER_ACCOUNT` drops an account whose 7-day channel union is too wide to be a
    # pool member — a genuine heavy viewer, not a dedicated bot.
    DEDICATED_MAX_CONCURRENT = 8
    MAX_CHANNELS_PER_ACCOUNT = 20
    MIN_EVENTS_PER_ACCOUNT = 2

    # Edge floor + cap. 5 shared accounts is the same floor Chat::PresenceQuery uses for an
    # audience edge; below it a pair is noise. The cap bounds a pathological sweep.
    MIN_ACCOUNTS_PER_PAIR = 5
    MAX_PAIRS = 5_000

    module_function

    # Compute one hour and write it. Idempotent: ReplacingMergeTree(hour, username) collapses a
    # re-run of the same hour instead of double-counting.
    #
    # Channels are UNIONED across the two phase grids while `events` takes the MAX — the phases are
    # two views of the same traffic, so counting events twice would inflate, but a channel seen in
    # only one grid is still evidence.
    def collect_hour!(hour_start)
      from = hour_start.utc.strftime("%Y-%m-%d %H:00:00")
      to = (hour_start.utc + 1.hour).strftime("%Y-%m-%d %H:00:00")

      Clickhouse.client.execute(<<~SQL)
        INSERT INTO coordination_events
        WITH bursts AS (
          SELECT username, phase,
                 toStartOfInterval(subtractSeconds(timestamp, phase), INTERVAL #{WINDOW_SECONDS} SECOND) AS bucket,
                 uniqExact(channel_login) AS ch,
                 groupUniqArray(channel_login) AS chans,
                 max(timestamp) AS bucket_last
          FROM chat_messages
          ARRAY JOIN [0, #{WINDOW_SECONDS / 2}] AS phase
          WHERE msg_type = 'privmsg' AND username != ''
            AND timestamp >= '#{from}' AND timestamp < '#{to}'
          GROUP BY username, phase, bucket
          HAVING ch >= #{MIN_CHANNELS}
        ),
        per_phase AS (
          SELECT username, phase,
                 count() AS ev_cnt,
                 max(ch) AS mc,
                 arrayDistinct(arrayFlatten(groupArray(chans))) AS chans_all,
                 max(bucket_last) AS last_ts
          FROM bursts GROUP BY username, phase
        )
        SELECT toDateTime('#{from}') AS hour,
               username,
               max(ev_cnt) AS events,
               max(mc) AS max_concurrent,
               arrayDistinct(arrayFlatten(groupArray(chans_all))) AS channels,
               max(last_ts) AS last_at
        FROM per_phase
        GROUP BY username
      SQL
      true
    end

    # Hours already collected in the lookback — lets the worker self-heal a gap (a restart, a paused
    # flag, a failed run) instead of silently leaving a hole in the window.
    def collected_hours(hours:)
      # The alias must NOT be `hour`: ClickHouse resolves the WHERE reference to the projection
      # alias (String) instead of the column (DateTime) and dies with NO_COMMON_TYPE. That killed
      # every hourly run for 18 hours before it was noticed — the collector's dead set was the only
      # trace. Same alias-shadowing family as `argMax(events, events)`.
      Clickhouse.client.select(<<~SQL).map { |r| Time.zone.parse("#{r['collected_hour']} UTC") }
        SELECT DISTINCT toString(hour) AS collected_hour
        FROM coordination_events
        WHERE hour >= toStartOfHour(now() - INTERVAL #{hours.to_i} HOUR)
      SQL
    end

    # The co-firing population over `days`, one row per account.
    # Returns Array<Hash>: username, events, max_concurrent, channels (Array<String>), last_at.
    def accounts(days:)
      rows = Clickhouse.client.select(<<~SQL)
        SELECT username,
               sum(events) AS events,
               max(max_concurrent) AS max_concurrent,
               arrayDistinct(arrayFlatten(groupArray(channels))) AS channels,
               max(last_at) AS last_at
        FROM coordination_events FINAL
        WHERE hour >= now() - INTERVAL #{days.to_i} DAY
        GROUP BY username
        HAVING events >= #{MIN_EVENTS_PER_ACCOUNT}
           AND max_concurrent <= #{DEDICATED_MAX_CONCURRENT}
           AND length(channels) <= #{MAX_CHANNELS_PER_ACCOUNT}
      SQL

      rows.map do |r|
        {
          username: r["username"],
          events: r["events"].to_i,
          max_concurrent: r["max_concurrent"].to_i,
          channels: Array(r["channels"]),
          last_at: r["last_at"]
        }
      end
    end

    # Channel↔channel edges: how many of those accounts co-fired in BOTH channels, and how many
    # events they carry. `a < b` keeps one row per unordered pair.
    # Returns Array<Hash>: a, b, accounts_shared, events.
    def channel_pairs(days:, min_accounts: MIN_ACCOUNTS_PER_PAIR)
      rows = Clickhouse.client.select(<<~SQL)
        WITH pool AS (
          SELECT username,
                 sum(events) AS events,
                 max(max_concurrent) AS max_concurrent,
                 arrayDistinct(arrayFlatten(groupArray(channels))) AS channels
          FROM coordination_events FINAL
          WHERE hour >= now() - INTERVAL #{days.to_i} DAY
          GROUP BY username
          HAVING events >= #{MIN_EVENTS_PER_ACCOUNT}
             AND max_concurrent <= #{DEDICATED_MAX_CONCURRENT}
             AND length(channels) <= #{MAX_CHANNELS_PER_ACCOUNT}
        )
        SELECT pair.1 AS a, pair.2 AS b, count() AS accounts_shared, sum(events) AS events
        FROM (
          SELECT username, events,
                 arrayJoin(arrayFilter(p -> p.1 < p.2,
                   arrayFlatten(arrayMap(x -> arrayMap(y -> (x, y), channels), channels)))) AS pair
          FROM pool
        )
        GROUP BY a, b
        HAVING accounts_shared >= #{min_accounts.to_i}
        ORDER BY accounts_shared DESC
        LIMIT #{MAX_PAIRS}
      SQL

      rows.map do |r|
        { a: r["a"], b: r["b"], accounts_shared: r["accounts_shared"].to_i, events: r["events"].to_i }
      end
    end

    # Per-account posting rhythm inside the group's channels — the "same periodicity" evidence.
    # Bounded on purpose: only the group's channels, only its accounts, only the last 24h.
    # Returns { username => { median_interval_sec:, interval_cv:, messages: } }.
    # `interval_cv` near zero = a metronome; a human's inter-message gaps scatter.
    def rhythm(channel_logins, usernames, hours: 24)
      return {} if channel_logins.blank? || usernames.blank?

      chans = channel_logins.map { |c| "'#{ChatQueries.escape_string_literal(c)}'" }.join(",")
      users = usernames.map { |u| "'#{ChatQueries.escape_string_literal(u)}'" }.join(",")

      rows = Clickhouse.client.select(<<~SQL)
        SELECT username,
               round(median(gap), 1) AS median_interval_sec,
               round(stddevPop(gap) / greatest(avg(gap), 0.001), 3) AS interval_cv,
               count() AS gaps
        FROM (
          SELECT username,
                 dateDiff('second',
                          lagInFrame(timestamp) OVER (PARTITION BY username ORDER BY timestamp),
                          timestamp) AS gap,
                 row_number() OVER (PARTITION BY username ORDER BY timestamp) AS rn
          FROM chat_messages
          WHERE msg_type = 'privmsg'
            AND channel_login IN (#{chans})
            AND username IN (#{users})
            AND timestamp > now() - INTERVAL #{hours.to_i} HOUR
        )
        -- rn > 1: the first message of each account has no predecessor, and lagInFrame's default
        -- (epoch 0) would otherwise contribute a ~1.7e9-second "gap" that swamps the spread.
        WHERE rn > 1 AND gap > 0
        GROUP BY username
        HAVING gaps >= 5
      SQL

      rows.each_with_object({}) do |r, acc|
        acc[r["username"]] = {
          median_interval_sec: r["median_interval_sec"].to_f,
          interval_cv: r["interval_cv"].to_f,
          messages: r["gaps"].to_i + 1
        }
      end
    end
  end
end
