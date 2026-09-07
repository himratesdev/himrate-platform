# frozen_string_literal: true

module Chat
  # Read side of the `chat_presence_daily` ClickHouse layer (db/clickhouse/005_*.sql): who chatted
  # in which channel on which day, deduped across the monitored archive and the farm capture.
  #
  # This is the audience-OVERLAP source (pautinka graph, brand overlap). It never feeds a verdict:
  # Trust Index / band / ERV keep reading `chat_messages` alone, so no accusation is ever computed
  # off farm data. Callers pick the population explicitly:
  #
  #   scope: :all        — monitored + farm (default; the dense answer for "who else do they watch")
  #   scope: :monitored  — monitored archive only (identical population to the TI engine; use it
  #                        when a number must reconcile with an engine-side figure)
  #
  # Noise controls mirror the previous Postgres implementation so verdict-adjacent semantics do not
  # drift: chatters present in more than MAX_USER_CHANNELS channels are serial lurkers/bots that
  # would wire everything to everything, and pairs below MIN_SHARED are noise.
  class PresenceQuery
    TABLE = "chat_presence_daily"
    DEFAULT_DAYS = 30
    MAX_USER_CHANNELS = 30
    MIN_SHARED = 5
    MAX_EDGES = 3000

    def initialize(days: DEFAULT_DAYS, scope: :all, client: Clickhouse::Client.new)
      @days = days.to_i.clamp(1, 90)
      @scope = scope.to_sym
      @client = client
    end

    # → { "login" => unique_chatters }
    def audiences(logins)
      return {} if logins.blank?

      rows = @client.select(<<~SQL)
        SELECT channel_login, uniqExact(username) AS audience
        FROM #{TABLE}
        WHERE #{window_filter} AND #{source_filter} AND channel_login IN (#{quoted(logins)})
        GROUP BY channel_login
      SQL
      rows.to_h { |r| [ r["channel_login"], r["audience"].to_i ] }
    end

    # → { "login" => days_with_any_observation } — coverage is asymmetric (the farm pool rotates),
    # so a thin-coverage channel under-reports its overlaps. Readers surface this instead of
    # silently comparing a fully-observed channel against a barely-observed one.
    def days_observed(logins)
      return {} if logins.blank?

      rows = @client.select(<<~SQL)
        SELECT channel_login, uniqExact(date) AS days
        FROM #{TABLE}
        WHERE #{window_filter} AND #{source_filter} AND channel_login IN (#{quoted(logins)})
        GROUP BY channel_login
      SQL
      rows.to_h { |r| [ r["channel_login"], r["days"].to_i ] }
    end

    # Pairwise shared chatters among `logins` → [{ a:, b:, shared: }], strongest first.
    # `a < b` lexicographically so every pair appears once.
    def edges(logins, min_shared: MIN_SHARED, limit: MAX_EDGES)
      return [] if logins.blank? || logins.size < 2

      rows = @client.select(<<~SQL)
        WITH linkers AS (
          -- A chatter can only create an edge INSIDE the asked-for set if they appear in at least
          -- two of those channels. Filtering on that first shrinks the self-join input by an order
          -- of magnitude (the global 2..N eligibility pass alone scanned every chatter we know).
          SELECT username
          FROM #{TABLE}
          WHERE #{window_filter} AND #{source_filter} AND channel_login IN (#{quoted(logins)})
          GROUP BY username
          HAVING uniqExact(channel_login) >= 2
        ),
        eligible AS (
          -- Serial-lurker cap stays global: someone sitting in more than MAX_USER_CHANNELS channels
          -- overall would wire everything to everything.
          SELECT username
          FROM #{TABLE}
          WHERE #{window_filter} AND #{source_filter} AND username IN (SELECT username FROM linkers)
          GROUP BY username
          HAVING uniqExact(channel_login) <= #{MAX_USER_CHANNELS}
        ),
        p AS (
          SELECT DISTINCT channel_login, username
          FROM #{TABLE}
          WHERE #{window_filter} AND #{source_filter}
            AND channel_login IN (#{quoted(logins)})
            AND username IN (SELECT username FROM eligible)
        )
        SELECT a.channel_login AS a, b.channel_login AS b, count() AS shared
        FROM p AS a
        INNER JOIN p AS b ON a.username = b.username
        WHERE a.channel_login < b.channel_login
        GROUP BY a, b
        HAVING shared >= #{min_shared.to_i}
        ORDER BY shared DESC
        LIMIT #{limit.to_i}
      SQL
      rows.map { |r| { a: r["a"], b: r["b"], shared: r["shared"].to_i } }
    end

    # First circle of one channel: who its chatters also chat with, strongest first.
    # → [{ login:, shared: }]. Unlike #edges this is NOT restricted to a known channel set — the
    # untracked neighbours are the discovery value of the ego view.
    def neighbours(login, min_shared: MIN_SHARED, limit: 60)
      rows = @client.select(<<~SQL)
        WITH mine AS (
          SELECT DISTINCT username
          FROM #{TABLE}
          WHERE #{window_filter} AND #{source_filter} AND channel_login = '#{escape(login)}'
        ),
        eligible AS (
          SELECT username
          FROM #{TABLE}
          WHERE #{window_filter} AND #{source_filter} AND username IN (SELECT username FROM mine)
          GROUP BY username
          HAVING uniqExact(channel_login) BETWEEN 2 AND #{MAX_USER_CHANNELS}
        )
        SELECT channel_login AS login, uniqExact(username) AS shared
        FROM #{TABLE}
        WHERE #{window_filter} AND #{source_filter}
          AND channel_login != '#{escape(login)}'
          AND username IN (SELECT username FROM eligible)
        GROUP BY login
        HAVING shared >= #{min_shared.to_i}
        ORDER BY shared DESC
        LIMIT #{limit.to_i}
      SQL
      rows.map { |r| { login: r["login"], shared: r["shared"].to_i } }
    end

    # Distinct chatter sets for a small channel list (brand overlap: 2-4 channels) —
    # → { "login" => Set[username] }. Bounded by the caller's channel count.
    def chatter_sets(logins)
      return {} if logins.blank?

      rows = @client.select(<<~SQL)
        SELECT channel_login, groupUniqArray(username) AS users
        FROM #{TABLE}
        WHERE #{window_filter} AND #{source_filter} AND channel_login IN (#{quoted(logins)})
        GROUP BY channel_login
      SQL
      logins.index_with { Set.new }.merge(
        rows.to_h { |r| [ r["channel_login"], Set.new(Array(r["users"])) ] }
      )
    end

    # Channels with the largest chat audience in the window, restricted to `within` when given.
    # → ["login", ...] ordered by audience DESC.
    def top_channels(limit, within: nil)
      scope_filter = within.present? ? "AND channel_login IN (#{quoted(within)})" : ""
      rows = @client.select(<<~SQL)
        SELECT channel_login, uniqExact(username) AS audience
        FROM #{TABLE}
        WHERE #{window_filter} AND #{source_filter} #{scope_filter}
        GROUP BY channel_login
        ORDER BY audience DESC
        LIMIT #{limit.to_i}
      SQL
      rows.map { |r| r["channel_login"] }
    end

    private

    def window_filter
      "date >= today() - #{@days}"
    end

    # Provenance filter — `:monitored` reproduces the engine-side population exactly.
    def source_filter
      @scope == :monitored ? "messages_monitored > 0" : "1"
    end

    def quoted(logins)
      Array(logins).map { |l| "'#{escape(l)}'" }.join(",")
    end

    def escape(login)
      login.to_s.downcase.gsub("\\", "\\\\\\\\").gsub("'", "''")
    end
  end
end
