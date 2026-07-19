# frozen_string_literal: true

module Brand
  # Audience overlap between 2-4 channels from the chat-presence graph (cross_channel_presences,
  # T1-057). This is CHAT-audience overlap (chatters), not all viewers — an honest chatters-only
  # basis (labelled audience_basis: "chat_presence"). Compute-on-read, bounded to 2-4 channels.
  class AudienceOverlapService
    MIN_CHANNELS = 2
    MAX_CHANNELS = 4
    Result = Struct.new(:ok, :error, :payload, keyword_init: true)

    def initialize(logins)
      @logins = Array(logins).map { |l| l.to_s.strip.downcase }.reject(&:blank?).uniq
    end

    def call
      return Result.new(ok: false, error: "CHANNELS_REQUIRED") unless @logins.size.between?(MIN_CHANNELS, MAX_CHANNELS)

      channels = Channel.where(login: @logins).to_a
      return Result.new(ok: false, error: "CHANNEL_NOT_FOUND") if (@logins - channels.map(&:login)).any?

      Result.new(ok: true, payload: build(channels))
    end

    private

    # Distinct chatter-username set per channel (within the selected set only). source: "live" keeps
    # the "chat_presence" basis honest — excludes future VOD-backfill edges (T1-058) that would
    # otherwise silently blend into live-stream chatters without a label distinction (CR nit-2).
    def channel_sets(channel_ids)
      sets = channel_ids.index_with { Set.new }
      CrossChannelPresence.where(channel_id: channel_ids, source: "live").distinct
                          .pluck(:channel_id, :username).each { |cid, user| sets[cid] << user }
      sets
    end

    def build(channels)
      by_id = channels.index_by(&:id)
      ids = channels.map(&:id)
      sets = channel_sets(ids)
      all_users = sets.values.reduce(Set.new, :|)
      channel_count = user_channel_counts(sets)

      {
        channels: channels.map { |c| { login: c.login, display_name: c.display_name, reach: sets[c.id].size } },
        unique_reach: all_users.size,
        total_reach: ids.sum { |cid| sets[cid].size },
        unique_percentage: pct(all_users.size, ids.sum { |cid| sets[cid].size }),
        matrix: matrix_for(ids, sets, by_id),
        pairwise: pairwise_for(ids, sets, by_id),
        composition: composition_for(ids, sets, channel_count, all_users, by_id),
        recommendations: recommendations_for(ids, sets, by_id),
        audience_basis: "chat_presence"
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
