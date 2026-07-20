# frozen_string_literal: true

# TASK-032 CR #6: Service object for Trust endpoint data assembly.
# Controller: params → service → render. No business logic in controller.

module Trust
  class ShowService
    def initialize(channel:, view:, user: nil)
      @channel = channel
      @view = view
      @user = user
    end

    def call
      payload = if v2_engine?
        build_headline_v2(latest_v2_ti)
      else
        build_headline(latest_trust_index, cold_start_data)
      end

      if @view == :drill_down || @view == :full
        payload.merge!(v2_engine? ? build_drill_down_v2 : build_drill_down(latest_trust_index))
        # TASK-085 FR-008 (ADR-085 D-4 OVERRIDE): anomaly_alerts gated за :drill_down/:full —
        # NOT :headline (Pundit contract preserved, no anonymous data leak).
        payload[:anomaly_alerts] = AnomalyAlertsPresenter.new(channel: @channel).call
      end

      if @view == :full
        payload.merge!(v2_engine? ? build_full_v2 : build_full)
      end

      payload
    end

    private

    def v2_engine?
      return @v2_engine if defined?(@v2_engine)

      @v2_engine =
        begin
          Flipper.enabled?(:ti_v2_engine)
        rescue StandardError
          false
        end
    end

    # PR3b (T1-074, B1): the v2 wire contract — ERV (subtracted count) + interval + authenticity +
    # 6-row band + reason_codes + plashka + cold_start_tier. NO ErvCalculator rescale. A channel
    # not recomputed since the flip → explicit "no v2 data" grey/insufficient shape (never renders
    # a stale v1 row as v2 — honest-empty doctrine).
    def build_headline_v2(tih)
      band = band_payload(tih)
      {
        channel_id: @channel.id,
        channel_login: @channel.login,
        erv: tih&.erv,
        erv_interval: { lo: tih&.erv_lo, hi: tih&.erv_hi },
        authenticity: tih&.authenticity&.to_f,
        band: band,
        # Server-resolved band label (RU/EN via I18n) — serves landing JS / server-rendered
        # surfaces; the extension translates label_key itself.
        erv_label: I18n.t(band[:label_key], default: nil),
        reason_codes: tih&.reason_codes || [],
        confirmed_anomaly: { shown: tih&.confirmed_anomaly || false },
        cold_start_tier: tih&.cold_start_tier,
        confidence_marker: tih&.confidence_marker || "provisional",
        engine_version: "v2",
        is_live: @channel.live?,
        ccv: latest_ccv,
        calculated_at: tih&.calculated_at&.iso8601
      }
    end

    # v2 drill: reason_codes replace the retired 14-signal breakdown (already in headline);
    # the post-stream window fields are engine-agnostic.
    def build_drill_down_v2
      {
        post_stream_expires_at: PostStreamWindowService.expires_at(@channel)&.iso8601,
        post_stream_window_expired: !@channel.live? && !PostStreamWindowService.open?(@channel) && @user&.tier == "free"
      }
    end

    def build_full_v2
      tih = latest_v2_ti
      reputation = @channel.streamer_reputation
      band = Reputation::BandService.cached_for(@channel)

      {
        streamer_reputation: reputation ? {
          growth_pattern_score: reputation.growth_pattern_score&.to_f,
          follower_quality_score: reputation.follower_quality_score&.to_f,
          engagement_consistency_score: reputation.engagement_consistency_score&.to_f
        } : nil,
        reputation_band: band[:band],
        reputation_tier: band[:tier],
        reputation_stream_count: band[:stream_count],
        erv_breakdown: erv_breakdown_v2(tih),
        bot_raid_victim: bot_raid_victim?,
        ti_protected: bot_raid_victim?,
        top_countries: top_countries_data,
        top_countries_status: top_countries_status
      }
    end

    # v2 breakdown: V and the fraud-arm decomposition off the same row ({v, f_hard, f_soft, f_hat} —
    # replaces real_viewers/bots_estimated; the subtraction is native, no derived "bots" framing).
    def erv_breakdown_v2(tih)
      return nil unless tih

      {
        v: tih.ccv&.to_i,
        f_hard: tih.f_hard&.to_f,
        f_soft: tih.f_soft&.to_f,
        f_hat: tih.f_hat&.to_f
      }
    end

    def band_payload(tih)
      return { row: 5, color: "grey", label_key: "band.grey_insufficient", sub: nil } unless tih&.band_row

      {
        row: tih.band_row,
        color: tih.band_color,
        label_key: TrustIndex::V2::BandClassifier::LABEL_KEYS_BY_ROW[tih.band_row],
        sub: tih.band_sub
      }
    end

    def latest_v2_ti
      @latest_v2_ti ||= @channel.trust_index_histories
                                .where(engine_version: "v2")
                                .order(calculated_at: :desc)
                                .first
    end

    def build_headline(latest_ti, cold_start)
      erv_data = erv_from_ti(latest_ti)

      {
        channel_id: @channel.id,
        channel_login: @channel.login,
        ti_score: latest_ti&.trust_index_score&.to_f,
        classification: latest_ti&.classification,
        # CR #8: clamp 0-100
        erv_percent: latest_ti&.erv_percent&.to_f&.clamp(0.0, 100.0),
        erv_count: erv_data[:erv_count],
        # CR #1: i18n-aware label
        erv_label: I18n.locale == :ru ? erv_data[:label] : erv_data[:label_en],
        erv_label_color: erv_data[:label_color],
        cold_start_status: cold_start[:status],
        confidence: latest_ti&.confidence&.to_f,
        confidence_display: erv_data[:confidence_display],
        is_live: @channel.live?,
        ccv: latest_ccv,
        # FR-013: Category percentile (CR #9: cached)
        category_avg_ti: category_avg_ti,
        percentile_in_category: cached_percentile(latest_ti),
        calculated_at: latest_ti&.calculated_at&.iso8601
      }
    end

    def build_drill_down(latest_ti)
      {
        signal_breakdown: signal_breakdown_for_stream,
        post_stream_expires_at: PostStreamWindowService.expires_at(@channel)&.iso8601,
        post_stream_window_expired: !@channel.live? && !PostStreamWindowService.open?(@channel) && @user&.tier == "free"
      }
    end

    def build_full
      reputation = @channel.streamer_reputation
      # T1-064 FR-3/FR-7: Reputation Categorical band (TI rolling window + anomaly distribution).
      # Additive to the flat streamer_reputation component scores (those stay for display).
      band = Reputation::BandService.cached_for(@channel)

      {
        streamer_reputation: reputation ? {
          growth_pattern_score: reputation.growth_pattern_score&.to_f,
          follower_quality_score: reputation.follower_quality_score&.to_f,
          engagement_consistency_score: reputation.engagement_consistency_score&.to_f
        } : nil,
        reputation_band: band[:band],
        reputation_tier: band[:tier],
        reputation_stream_count: band[:stream_count],
        erv_breakdown: erv_breakdown,
        bot_raid_victim: bot_raid_victim?,
        ti_protected: bot_raid_victim?,
        # TASK-035 FR-033: top countries from chatters demographic data
        top_countries: top_countries_data,
        # T1-064 FR-5: explicit availability status instead of an ambiguous bare nil
        # (the ambiguity is what let the frontend fabricate demo numbers).
        top_countries_status: top_countries_status
      }
    end

    def latest_trust_index
      # PR3b: explicit v1 filter — flag-flap safety (an unfiltered latest could pick a v2 row
      # whose v1 columns are NULL). Pre-flip behavior identical (only v1 rows exist).
      @latest_ti ||= @channel.trust_index_histories
                              .where(engine_version: "v1")
                              .order(calculated_at: :desc)
                              .first
    end

    def latest_ccv
      current_stream = @channel.streams.where(ended_at: nil).order(started_at: :desc).first
      return nil unless current_stream

      CcvSnapshot.where(stream: current_stream).order(timestamp: :desc).pick(:ccv_count)
    end

    def cold_start_data
      stream_count = @channel.streams.where.not(ended_at: nil).count
      TrustIndex::ColdStartGuard.assess_hash(stream_count)
    end

    def erv_from_ti(ti)
      return { erv_count: nil, label: nil, label_en: nil, label_color: nil, confidence_display: { type: "insufficient" } } unless ti

      TrustIndex::ErvCalculator.compute(
        ti_score: ti.trust_index_score.to_f,
        ccv: ti.ccv.to_i,
        confidence: ti.confidence.to_f
      )
    end

    # BUG-TI-SIGNAL-BREAKDOWN (2026-06-01): read signals from latest TIH.signal_breakdown
    # JSON column (canonical post TrustIndex::Engine refactor). The `signals` PG table
    # is dead-write since the Engine refactor — TiSignal.create! call no longer exists in
    # the worker path, the table sits at 0 rows. Reading from it returned `[]` for every
    # caller (drill_down panel empty for all Free users on live channels).
    #
    # TIH.signal_breakdown JSON schema (per TrustIndex::Engine):
    #   { "auth_ratio" => { "value" => 0.0, "weight" => 0.21, "confidence" => 1.0, "contribution" => 0.0 }, ... }
    # The `metadata` field old TiSignal carried is intentionally not preserved — it was
    # signal-specific debug context, not consumed by the API contract per current Blueprinter
    # specs (TrustIndexBlueprint drill_down view exposes only value/weight/confidence/contribution).
    def signal_breakdown_for_stream
      tih = latest_trust_index
      return [] unless tih

      breakdown = tih.signal_breakdown
      return [] unless breakdown.is_a?(Hash)

      breakdown.map do |signal_type, data|
        next nil unless data.is_a?(Hash)

        {
          type: signal_type,
          value: data["value"]&.to_f,
          confidence: data["confidence"]&.to_f,
          weight: data["weight"]&.to_f,
          # contribution is always written by TrustIndex::Engine (engine.rb:116-121); read
          # canonical, no defensive fallback — schema drift should surface, not be papered over.
          contribution: data["contribution"]&.to_f,
          metadata: nil
        }
      end.compact
    end

    def category_avg_ti
      current_stream = @channel.streams.order(started_at: :desc).first
      category = current_stream&.game_name || "default"

      SignalConfiguration.value_for("trust_index", category, "category_avg_ti")
    rescue SignalConfiguration::ConfigurationMissing
      nil
    end

    # Percentile feature returns nil until a rolling-window replacement metric ships.
    def cached_percentile(_latest_ti)
      nil
    end

    def erv_breakdown
      ti = latest_trust_index
      return nil unless ti

      ccv = ti.ccv.to_i
      erv_count = (ccv * ti.trust_index_score.to_f / 100.0).round
      bots = ccv - erv_count

      {
        ccv: ccv,
        real_viewers: erv_count,
        bots_estimated: [ bots, 0 ].max,
        confidence: ti.confidence&.to_f
      }
    end

    def bot_raid_victim?
      current_stream = @channel.streams.order(started_at: :desc).first
      return false unless current_stream

      RaidAttribution.where(stream: current_stream, is_bot_raid: true)
                     .where.not(source_channel_id: @channel.id)
                     .exists?
    end

    # TASK-035 FR-033: Top countries from chatters demographic data.
    # FND-002: API field exists for future population. Currently returns nil
    # because chatters_snapshots does not yet collect country_distribution.
    # When demographic pipeline is built (TASK-040 Audience), this method
    # will query the data. API contract is stable — UI hides module when null.
    def top_countries_data
      nil
    end

    # T1-064 FR-5: availability contract — {available | empty | not_implemented}.
    # Audience demographic pipeline (TASK-040) not built → not_implemented (honest, not nil-guess).
    def top_countries_status
      data = top_countries_data
      return "not_implemented" if data.nil?

      data.empty? ? "empty" : "available"
    end
  end
end
