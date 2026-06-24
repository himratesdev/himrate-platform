# frozen_string_literal: true

# T1-061: unified channel-card object — the same reusable object in the extension (in-Twitch,
# free layers) and the dashboard/ЛК (web, + paid role layers). Generalizes the former
# streamer-own /card into a layered card for ANY viewer, gated by surface + role + payment
# (access-model v2 / T1-060). Thin assembler: delegates to Trust::ShowService (layers 1-2) +
# Reputation::HistoryService (layer 3, T1-065) + ChannelPolicy (per-layer access). NEVER calls
# Trust::ShowService(view: :full) — reputation comes only from T1-065 (DEC-4 build_full reconcile).
#
# GATE-THEN-ASSEMBLE (DEC-2): per-layer access is decided FIRST; a layer's data block is invoked
# ONLY when that layer is granted — owner-only data (stats/recent_streams) is never assembled for
# non-owners.
module Cards
  class CardService
    EXTENSION = Auth::AuthContext::EXTENSION
    DASHBOARD = Auth::AuthContext::DASHBOARD
    TRUST_CACHE_TTL = 30.seconds
    RECENT_STREAMS_LIMIT = 5

    def initialize(channel:, context:)
      @channel = channel
      @context = context                 # Auth::AuthContext (user + surface)
      @user = context.user
      @policy = ChannelPolicy.new(context, channel)
    end

    def call
      {
        channel: channel_meta,
        surface: @context.surface,
        layers: {
          headline:     { available: true, data: headline_data },
          live_drill:   live_drill_layer(live_drill_granted?),
          reputation:   { available: true, data: Reputation::HistoryService.cached_for(@channel) },
          period_depth: paid_layer(@policy.card_period_depth?, :period_depth) { period_depth_data },
          role_tools:   paid_layer(@policy.card_role_tools?, :role_tools) { {} }
        }
      }
    end

    private

    def extension?
      @context.surface == EXTENSION
    end

    # Memoized — used both for the live_drill layer and to pick the Trust::ShowService view, so
    # card_live_drill? (and its record.live?/window checks) runs once per request.
    def live_drill_granted?
      return @live_drill_granted if defined?(@live_drill_granted)

      @live_drill_granted = @policy.card_live_drill?
    end

    def channel_meta
      {
        login: @channel.login,
        display_name: @channel.display_name,
        avatar_url: @channel.profile_image_url,
        partner_status: @channel.broadcaster_type,
        created_at: @channel.created_at.iso8601,
        followers_count: @channel.followers_total
      }
    end

    # Layer 1 (always) + layer 2 (drill) share one Trust::ShowService call — pick the richest view
    # the caller is entitled to. NEVER :full (DEC-4); reputation_band is intentionally not read here.
    def trust_payload
      @trust_payload ||= begin
        view = live_drill_granted? ? :drill_down : :headline
        # Reuses the TrustController cache key (trust:id:view) — intentionally NOT scoped by
        # user/surface. Safe today: the only user-dependent drill field (post_stream_window_expired)
        # is always false whenever :drill_down is reachable here. A future user-specific field in
        # build_drill_down would leak across users — scope the key by user then.
        Rails.cache.fetch("trust:#{@channel.id}:#{view}", expires_in: TRUST_CACHE_TTL) do
          Trust::ShowService.new(channel: @channel, view: view, user: @user).call
        end
      end
    end

    def headline_data
      trust_payload.slice(
        :ti_score, :classification, :erv_percent, :erv_count, :erv_label, :erv_label_color,
        :cold_start_status, :confidence, :is_live, :ccv, :calculated_at
      )
    end

    # Layer 2: free, but registered + (live OR post-stream window). Guest on a live/window channel
    # gets a register CTA (funnel); a registered viewer on an offline channel just gets unavailable.
    def live_drill_layer(granted)
      return { available: true, data: trust_payload.slice(:signal_breakdown, :anomaly_alerts, :post_stream_expires_at, :post_stream_window_expired) } if granted

      layer = { available: false }
      layer[:cta] = { action: "register" } if @user.nil? && live_or_window?
      layer
    end

    def live_or_window?
      @channel.live? || PostStreamWindowService.open?(@channel)
    end

    # Layers 4-5 (paid, dashboard-only). Extension → always omitted + open_dashboard CTA (NEVER
    # SUBSCRIPTION_REQUIRED — T1-060 invariant). Dashboard → data if granted, else subscribe CTA.
    def paid_layer(granted, _layer)
      if extension?
        { available: false, surface_allowed: [ DASHBOARD ], cta: { action: "open_dashboard" } }
      elsif granted
        { available: true, data: yield }
      else
        { available: false, surface_allowed: [ DASHBOARD ], cta: { action: "subscribe", code: "SUBSCRIPTION_REQUIRED" } }
      end
    end

    # Layer 4 data (owner/paid on dashboard) — the former own-card stats + recent streams (light
    # period summary). Deep period-drill (cohorts / movement) is EPIC-DRILLDOWN, surfaced as a link.
    def period_depth_data
      completed = @channel.streams.where.not(ended_at: nil)
      recent = completed.includes(:post_stream_report).order(ended_at: :desc).limit(RECENT_STREAMS_LIMIT)
      recent_ti = prefetch_ti_for_streams(recent, @channel.id)

      {
        stats: stream_stats(completed),
        recent_streams: recent.map { |s| format_stream(s, recent_ti[s.id]) },
        deep_drill_url: nil # EPIC-DRILLDOWN: period cohorts/movement (not yet implemented)
      }
    end

    # --- ported from ChannelsController (card-only helpers) ---

    def stream_stats(completed_streams)
      agg = completed_streams
        .joins("INNER JOIN post_stream_reports ON post_stream_reports.stream_id = streams.id")
        .where.not(post_stream_reports: { ccv_avg: nil })
        .pick(
          Arel.sql("COUNT(streams.id)"),
          Arel.sql("AVG(post_stream_reports.ccv_avg)"),
          Arel.sql("MAX(post_stream_reports.ccv_peak)"),
          Arel.sql("AVG(post_stream_reports.duration_ms)")
        )

      {
        total_streams: agg[0].to_i,
        avg_ccv: agg[1]&.to_i,
        peak_ccv: agg[2]&.to_i,
        avg_duration_hours: agg[3] ? (agg[3].to_f / 3_600_000).round(1) : nil,
        streams_per_week: streams_per_week
      }
    end

    # Denominator aligned with stream_stats total (same "completed ended streams with PSR" set).
    def streams_per_week
      first_stream = @channel.streams.order(:started_at).first
      return nil unless first_stream

      weeks = [ (Time.current - first_stream.started_at) / 1.week, 1 ].max
      total = @channel.streams
                      .where.not(ended_at: nil)
                      .joins("INNER JOIN post_stream_reports ON post_stream_reports.stream_id = streams.id")
                      .where.not(post_stream_reports: { ccv_avg: nil })
                      .count
      (total.to_f / weeks).round(1)
    end

    # Single query for all recent streams' TI records (no N+1).
    def prefetch_ti_for_streams(streams, channel_id)
      return {} if streams.empty?

      min_start = streams.map(&:started_at).min
      max_end = streams.map { |s| s.ended_at || Time.current }.max

      all_ti = TrustIndexHistory
        .where(channel_id: channel_id)
        .where(calculated_at: min_start..max_end)
        .order(calculated_at: :desc)

      streams.to_h do |s|
        ti = all_ti.find { |t| t.calculated_at.between?(s.started_at, s.ended_at || Time.current) }
        [ s.id, ti ]
      end
    end

    def format_stream(stream, ti = nil)
      duration_ms = stream.current_duration_ms
      {
        date: stream.started_at.iso8601,
        duration_hours: duration_ms ? (duration_ms / 3_600_000.0).round(1) : nil,
        peak_ccv: stream.current_peak_ccv,
        avg_ccv: stream.current_avg_ccv,
        ti_score: ti&.trust_index_score&.to_f&.round(1),
        erv_percent: ti&.erv_percent&.to_f&.round(1)
      }
    end
  end
end
