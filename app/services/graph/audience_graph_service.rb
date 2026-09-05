# frozen_string_literal: true

module Graph
  # W5 «Паутинка»: the audience-overlap graph over the chat-presence ledger
  # (cross_channel_presences, T1-057). Nodes = channels (size = unique chat audience, colour =
  # latest v2 band), edges = shared-chatter counts between channel pairs. Honest basis: this is
  # CHAT audience (the platform-wide viewer list does not exist — chatters-only disclaimer).
  #
  # Noise control: "power users" present in > MAX_USER_CHANNELS channels are excluded from edge
  # building (serial lurkers/bots would wire everything to everything); pairs below MIN_SHARED
  # are dropped. Full mode covers the TOP_CHANNELS by audience; focus mode is a channel's
  # first-circle ego graph. Compute-on-read behind a Rails.cache (grow-style).
  class AudienceGraphService
    TOP_CHANNELS = 200
    MIN_SHARED = 5
    MAX_USER_CHANNELS = 30
    CACHE_TTL = 1.hour
    FOCUS_CACHE_TTL = 10.minutes

    def self.call(focus: nil)
      key = focus ? "graph:audience:focus:#{focus}" : "graph:audience:full"
      Rails.cache.fetch(key, expires_in: focus ? FOCUS_CACHE_TTL : CACHE_TTL) do
        new(focus: focus).build
      end
    end

    def initialize(focus: nil)
      @focus = focus.to_s.strip.downcase.presence
    end

    def build
      focus_channel = nil
      if @focus
        focus_channel = Channel.find_by(login: @focus)
        return { error: "CHANNEL_NOT_FOUND" } unless focus_channel
      end

      edges = fetch_edges(focus_channel)
      node_ids = edges.flat_map { |e| [ e["a_id"], e["b_id"] ] }.uniq
      node_ids << focus_channel.id if focus_channel && node_ids.exclude?(focus_channel.id)
      nodes = fetch_nodes(node_ids)
      audience = nodes.to_h { |n| [ n[:id], n[:audience] ] }

      {
        basis: "chat_presence",
        generated_at: Time.current.iso8601,
        focus: @focus,
        nodes: nodes,
        edges: edges.map do |e|
          denom = [ audience[e["a_id"]], audience[e["b_id"]] ].compact.min
          { a: e["a_id"], b: e["b_id"], shared: e["shared"].to_i,
            share: denom.to_i.positive? ? (e["shared"].to_f / denom).round(3) : nil }
        end
      }
    end

    private

    # Pairwise shared-chatter counts. Full mode restricts both endpoints to the top-N channels;
    # focus mode takes every edge incident to the focus channel (its whole first circle).
    def fetch_edges(focus_channel)
      scope_join, scope_filter =
        if focus_channel
          [ "", "AND (a.channel_id = :focus OR b.channel_id = :focus)" ]
        else
          [ "JOIN top_channels ta ON ta.channel_id = a.channel_id
             JOIN top_channels tb ON tb.channel_id = b.channel_id", "" ]
        end

      sql = <<~SQL
        WITH eligible AS (
          SELECT username FROM cross_channel_presences
          GROUP BY username
          HAVING COUNT(DISTINCT channel_id) BETWEEN 2 AND :max_ch
        ),
        top_channels AS (
          SELECT channel_id FROM cross_channel_presences
          GROUP BY channel_id
          ORDER BY COUNT(DISTINCT username) DESC
          LIMIT :top_n
        ),
        p AS (
          SELECT DISTINCT ccp.channel_id, ccp.username
          FROM cross_channel_presences ccp
          JOIN eligible e ON e.username = ccp.username
        )
        SELECT a.channel_id AS a_id, b.channel_id AS b_id, COUNT(*) AS shared
        FROM p a
        JOIN p b ON a.username = b.username AND a.channel_id < b.channel_id
        #{scope_join}
        WHERE TRUE #{scope_filter}
        GROUP BY 1, 2
        HAVING COUNT(*) >= :min_shared
        ORDER BY shared DESC
        LIMIT 3000
      SQL

      binds = { max_ch: MAX_USER_CHANNELS, top_n: TOP_CHANNELS, min_shared: MIN_SHARED }
      binds[:focus] = focus_channel.id if focus_channel
      ActiveRecord::Base.connection.select_all(
        ActiveRecord::Base.sanitize_sql([ sql, binds ])
      ).to_a
    end

    def fetch_nodes(ids)
      return [] if ids.empty?

      audiences = CrossChannelPresence.where(channel_id: ids)
                                      .group(:channel_id).distinct.count(:username)
      bands = TrustIndexHistory
              .where(channel_id: ids, engine_version: "v2")
              .select("DISTINCT ON (channel_id) channel_id, band_color")
              .order(:channel_id, calculated_at: :desc)
              .to_h { |t| [ t.channel_id, t[:band_color] ] }
      Channel.where(id: ids).map do |ch|
        { id: ch.id, login: ch.login, name: ch.display_name || ch.login,
          audience: audiences[ch.id].to_i, band: bands[ch.id] || "grey" }
      end
    end
  end
end
