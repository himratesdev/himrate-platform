# frozen_string_literal: true

module Graph
  # W5 «Паутинка»: the audience-overlap graph. Nodes = channels (size = unique chat audience,
  # colour = latest v2 band), edges = shared-chatter counts between channel pairs.
  #
  # Source (2026-09): the ClickHouse presence layer `chat_presence_daily` (Chat::PresenceQuery) —
  # the monitored chat archive PLUS the farm's category-join capture, deduped per (day, channel,
  # chatter). The previous Postgres `cross_channel_presences` ledger only covered the monitored set
  # and restarted with the 2026-08 server migration, so real channel pairs showed "0 shared".
  # Postgres is not written to for this at all; CH already had both streams.
  #
  # Mixed-source discipline: this graph answers "who else does this audience watch". Verdicts
  # (TI / band / ERV) keep running on the monitored archive alone — farm chat never enters an
  # accusation. Nodes carry `tracked` so a channel we do not monitor (no verdict, band "grey") is
  # visibly different from one we do.
  #
  # Honest basis: this is CHAT audience (the platform-wide viewer list does not exist).
  # Noise control lives in Chat::PresenceQuery (serial-lurker cap, min-shared floor).
  class AudienceGraphService
    TOP_CHANNELS = 200
    EGO_NEIGHBOURS = 60
    WINDOW_DAYS = 30
    CACHE_TTL = 1.hour
    FOCUS_CACHE_TTL = 10.minutes

    def self.call(focus: nil)
      key = focus ? "graph:audience:v2:focus:#{focus}" : "graph:audience:v2:full"
      Rails.cache.fetch(key, expires_in: focus ? FOCUS_CACHE_TTL : CACHE_TTL) do
        new(focus: focus).build
      end
    end

    def initialize(focus: nil)
      @focus = focus.to_s.strip.downcase.presence
      @presence = Chat::PresenceQuery.new(days: WINDOW_DAYS)
    end

    def build
      return { error: "CHANNEL_NOT_FOUND" } if @focus && Channel.find_by(login: @focus).nil?

      logins = @focus ? ego_logins : full_logins
      return empty_payload if logins.empty?

      edges = @presence.edges(logins)
      truncated = edges.size >= Chat::PresenceQuery::MAX_EDGES
      audience = @presence.audiences(logins)
      # Drop nodes the edge set never mentions (in full mode a tie-less node is unreadable dust);
      # the ego channel always stays so its "no overlaps yet" state is honest, not empty.
      linked = edges.flat_map { |e| [ e[:a], e[:b] ] }.to_set
      linked << @focus if @focus
      nodes = build_nodes(logins.select { |l| linked.include?(l) }, audience)

      {
        basis: "chat_presence",
        basis_source: "clickhouse_presence",
        window_days: WINDOW_DAYS,
        generated_at: Time.current.iso8601,
        focus: @focus,
        # The denser CH source can exceed the edge budget; say so instead of passing a silently
        # truncated top-N off as the whole picture (the UI shows "показаны сильнейшие связи").
        edges_truncated: truncated,
        nodes: nodes,
        edges: edges.map do |e|
          denom = [ audience[e[:a]], audience[e[:b]] ].compact.min
          { a: e[:a], b: e[:b], shared: e[:shared],
            share: denom.to_i.positive? ? (e[:shared].to_f / denom).round(3) : nil }
        end
      }
    end

    private

    def empty_payload
      { basis: "chat_presence", basis_source: "clickhouse_presence", window_days: WINDOW_DAYS,
        generated_at: Time.current.iso8601, focus: @focus, nodes: [], edges: [] }
    end

    # Full mode: the top monitored channels by chat audience — every node carries a verdict, which
    # is what the colour axis means. (Untracked farm channels appear only in ego mode, where the
    # question is "where else does THIS audience go".)
    def full_logins
      monitored = Channel.where(is_monitored: true, deleted_at: nil).pluck(:login)
      @presence.top_channels(TOP_CHANNELS, within: monitored)
    end

    # Ego mode: the channel plus its strongest first circle — including channels we do not track
    # (they are exactly the discovery value; they render grey/untracked).
    def ego_logins
      neighbours = @presence.neighbours(@focus, limit: EGO_NEIGHBOURS).map { |n| n[:login] }
      ([ @focus ] + neighbours).uniq
    end

    def build_nodes(logins, audience)
      channels = Channel.where(login: logins).index_by(&:login)
      ids = channels.values.map(&:id)
      bands = latest_bands(ids)
      latest_streams = Stream.where(channel_id: ids)
                             .select("DISTINCT ON (channel_id) channel_id, game_name, language")
                             .order("channel_id, started_at DESC")
                             .index_by(&:channel_id)

      logins.map do |login|
        channel = channels[login]
        stream = channel && latest_streams[channel.id]
        # `id` is the login: it keys nodes to edges and stays stable for channels that have no
        # Channel row at all (farm-only neighbours).
        { id: login, login: login,
          name: channel&.display_name.presence || login,
          audience: audience[login].to_i,
          band: (channel && bands[channel.id]) || "grey",
          tracked: channel.present?,
          category: stream&.game_name.presence,
          language: stream&.language.presence&.upcase }
      end
    end

    def latest_bands(ids)
      return {} if ids.empty?

      TrustIndexHistory
        .where(channel_id: ids, engine_version: "v2")
        .select("DISTINCT ON (channel_id) channel_id, band_color")
        .order(:channel_id, calculated_at: :desc)
        .to_h { |t| [ t.channel_id, t[:band_color] ] }
    end
  end
end
