# frozen_string_literal: true

module Brand
  # Audience overlap between 2-4 channels from the chat-presence graph (cross_channel_presences,
  # T1-057). This is CHAT-audience overlap (chatters), not all viewers — an honest chatters-only
  # basis (labelled audience_basis: "chat_presence"). Compute-on-read, bounded to 2-4 channels.
  class AudienceOverlapService
    MIN_CHANNELS = 2
    MAX_CHANNELS = 4
    WINDOW_DAYS = 30 # matches the graph window; both sources cover it (farm capture TTL = 30d)
    Result = Struct.new(:ok, :error, :payload, keyword_init: true)

    def initialize(logins)
      @logins = Array(logins).map { |l| l.to_s.strip.downcase }.reject(&:blank?).uniq
    end

    def call
      return Result.new(ok: false, error: "CHANNELS_REQUIRED") unless @logins.size.between?(MIN_CHANNELS, MAX_CHANNELS)

      # Preserve the REQUESTED channel order (Channel.where(login:) returns DB order, which varies with
      # heap/index state) — otherwise the matrix/pairwise column order and each pair's (a, b) assignment
      # are non-deterministic (source of the audience_overlap_service_spec full-suite seed flake), and
      # the rendered overlap columns wouldn't match the order the brand asked for.
      by_login = Channel.where(login: @logins).index_by(&:login)
      return Result.new(ok: false, error: "CHANNEL_NOT_FOUND") if (@logins - by_login.keys).any?

      channels = @logins.map { |login| by_login[login] }
      Result.new(ok: true, payload: build(channels))
    end

    private

    # Distinct chatter-username set per channel, read from the ClickHouse presence layer
    # (Chat::PresenceQuery — monitored archive + farm capture, deduped; db/clickhouse/005). The
    # Postgres `cross_channel_presences` ledger covers only the monitored set and restarted with
    # the 2026-08 server migration, which made real channel pairs read "0 shared"; ClickHouse
    # already holds both sources. Falls back to the ledger when CH is unavailable so the page
    # degrades instead of erroring — the payload always states which basis produced the numbers.
    def channel_sets(channels)
      sets = Chat::PresenceQuery.new(days: WINDOW_DAYS).chatter_sets(channels.map(&:login))
      @basis_source = "clickhouse_presence"
      channels.to_h { |c| [ c.id, sets[c.login] || Set.new ] }
    rescue StandardError => e
      Rails.logger.warn("AudienceOverlapService: ClickHouse presence unavailable (#{e.class}) — ledger fallback")
      @basis_source = "pg_ledger"
      ledger_sets(channels.map(&:id))
    end

    def ledger_sets(channel_ids)
      sets = channel_ids.index_with { Set.new }
      CrossChannelPresence.where(channel_id: channel_ids, source: "live").distinct
                          .pluck(:channel_id, :username).each { |cid, user| sets[cid] << user }
      sets
    end

    # Coverage is asymmetric — the farm pool rotates, so one channel can be observed on fewer days
    # than another. Surfacing it stops a thin-coverage pair from reading as "these audiences barely
    # overlap" when the truth is "we watched one of them less".
    def coverage_days(channels)
      Chat::PresenceQuery.new(days: WINDOW_DAYS).days_observed(channels.map(&:login))
    rescue StandardError
      {}
    end

    def build(channels)
      by_id = channels.index_by(&:id)
      ids = channels.map(&:id)
      sets = channel_sets(channels)
      coverage = coverage_days(channels)
      all_users = sets.values.reduce(Set.new, :|)
      channel_count = user_channel_counts(sets)

      {
        channels: channels.map do |c|
          { login: c.login, display_name: c.display_name, reach: sets[c.id].size,
            days_observed: coverage[c.login] }
        end,
        unique_reach: all_users.size,
        total_reach: ids.sum { |cid| sets[cid].size },
        unique_percentage: pct(all_users.size, ids.sum { |cid| sets[cid].size }),
        matrix: matrix_for(ids, sets, by_id),
        pairwise: pairwise_for(ids, sets, by_id),
        composition: composition_for(ids, sets, channel_count, all_users, by_id),
        recommendations: recommendations_for(ids, sets, by_id),
        audience_basis: "chat_presence",
        basis_source: @basis_source,
        window_days: WINDOW_DAYS
      }
    end

    def user_channel_counts(sets)
      counts = Hash.new(0)
      sets.each_value { |set| set.each { |user| counts[user] += 1 } }
      counts
    end

    # % of row-channel chatters also present in column-channel (self = 100).
    def matrix_for(ids, sets, by_id)
      ids.to_h do |a|
        row = ids.to_h { |b| [ by_id[b].login, a == b ? 100.0 : pct((sets[a] & sets[b]).size, sets[a].size) ] }
        [ by_id[a].login, row ]
      end
    end

    def pairwise_for(ids, sets, by_id)
      ids.combination(2).map do |a, b|
        shared = (sets[a] & sets[b]).size
        percent = pct(shared, [ sets[a].size, sets[b].size ].min)
        { a: by_id[a].login, b: by_id[b].login, shared: shared, percent: percent, strength: strength(percent) }
      end
    end

    def composition_for(ids, sets, channel_count, all_users, by_id)
      only = ids.map do |cid|
        n = sets[cid].count { |u| channel_count[u] == 1 }
        { segment: "only_#{by_id[cid].login}", count: n, percent: pct(n, all_users.size) }
      end
      shared = all_users.count { |u| channel_count[u] >= 2 }
      only + [ { segment: "shared_2plus", count: shared, percent: pct(shared, all_users.size) } ]
    end

    # Rank pairs by LOW mutual overlap (more unique reach = better spend). risk mirrors strength.
    def recommendations_for(ids, sets, by_id)
      pairwise_for(ids, sets, by_id).sort_by { |p| p[:percent] }.map do |p|
        { combo: [ p[:a], p[:b] ], unique_percent: (100.0 - p[:percent]).round(1), risk: risk(p[:percent]) }
      end
    end

    def pct(numerator, denominator)
      denominator.zero? ? 0.0 : ((numerator.to_f / denominator) * 100).round(1)
    end

    def strength(percent)
      percent < 15 ? "weak" : (percent <= 35 ? "medium" : "strong")
    end

    def risk(percent)
      percent < 15 ? "max_reach" : (percent <= 35 ? "optimal" : "caution")
    end
  end
end
