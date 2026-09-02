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
      payload = build_headline_v2(latest_v2_ti)

      if @view == :drill_down || @view == :full
        payload.merge!(build_drill_down_v2)
        # TASK-085 FR-008 (ADR-085 D-4 OVERRIDE): anomaly_alerts gated за :drill_down/:full —
        # NOT :headline (Pundit contract preserved, no anonymous data leak).
        payload[:anomaly_alerts] = AnomalyAlertsPresenter.new(channel: @channel).call
      end

      payload.merge!(build_full_v2) if @view == :full

      payload
    end

    private

    # PR3b (T1-074, B1): the v2 wire contract — ERV (subtracted count) + interval + authenticity +
    # 6-row band + reason_codes + plashka + cold_start_tier. NO ErvCalculator rescale. A channel
    # not recomputed since the flip → explicit "no v2 data" grey/insufficient shape (never renders
    # a stale v1 row as v2 — honest-empty doctrine).
    def build_headline_v2(tih)
      band = band_payload(tih)
      {
        channel_id: @channel.id,
        channel_login: @channel.login,
        is_live: @channel.live?,
        state: @channel.live? ? "live" : "offline",
        erv: tih&.erv,
        erv_interval: { lo: tih&.erv_lo, hi: tih&.erv_hi },
        # Flat authenticity stays as a SUPERSET bridge (landing JS + the extension's flat-first
        # readAuthenticity read it); the SRS-canonical nested form lives in axes below.
        authenticity: tih&.authenticity&.to_f,
        axes: axes_v2(tih),
        band: band,
        # Server-resolved band label (RU/EN via I18n) — serves landing JS / server-rendered
        # surfaces; the extension translates label_key itself.
        erv_label: I18n.t(band[:label_key], default: nil),
        # Contract: bare code strings on the headline; {code, label_key, params} objects are the
        # drill's reason_codes_detail (extension + SRS both expect string[] here).
        reason_codes: reason_code_strings(tih),
        confirmed_anomaly: { shown: tih&.confirmed_anomaly || false, provenance: provenance_v2(tih) },
        cold_start_tier: tih&.cold_start_tier,
        confidence_marker: tih&.confidence_marker || "provisional",
        engine_version: "v2",
        ccv: latest_ccv,
        calculated_at: tih&.calculated_at&.iso8601
      }
    end

    # SRS §4A axes — single source: TrustIndex::V2::AxesBuilder (same shape the engine emits).
    # Reputation from the domain cache; chat_share = persisted windowed/cumulative ρ_obs; CPS null
    # until the protection-score pipeline feeds the v2 context (extension tolerates null).
    def axes_v2(tih)
      TrustIndex::V2::AxesBuilder.call(
        authenticity: tih&.authenticity&.to_f,
        authenticity_lo: tih&.authenticity_lo&.to_f,
        authenticity_hi: tih&.authenticity_hi&.to_f,
        reputation: reputation_band_cached,
        rho_obs: tih&.rho_obs&.to_f,
        cps: nil
      ).to_h
    end

    def reputation_band_cached
      @reputation_band_cached ||= Reputation::BandService.cached_for(@channel)
    rescue StandardError
      nil
    end

    # Persisted reason_codes are [{"code"=>..., "params"=>...}] hashes (V2::Persistence writes
    # Code#to_h); tolerate legacy bare strings.
    def reason_code_strings(tih)
      (tih&.reason_codes || []).map { |c| c.is_a?(Hash) ? (c["code"] || c[:code]) : c }.compact
    end

    # SRS: provenance names the corroboration that let the plashka render — hard named-bot
    # evidence or the channel's own inflation self-history. nil when nothing is confirmed.
    def provenance_v2(tih)
      return nil unless tih&.confirmed_anomaly

      return "HARD_NAMED_FRACTION" if tih.c_hard
      return "SELF_HISTORY_INFLATION_EVENT" if tih.c_self

      nil
    end

    # v2 drill (SRS §4A :drill_down / extension CardLiveDrillData — every key REQUIRED, empty
    # collections over missing keys): the F̂ decomposition + detailed reason codes + the L0/L2
    # signal breakdown, plus the engine-agnostic post-stream window fields.
    def build_drill_down_v2
      tih = latest_v2_ti
      {
        erv_breakdown: erv_breakdown_v2(tih),
        reason_codes_detail: reason_codes_detail_v2(tih),
        signal_breakdown: signal_breakdown_v2(tih),
        post_stream_expires_at: PostStreamWindowService.expires_at(@channel)&.iso8601,
        post_stream_window_expired: !@channel.live? && !PostStreamWindowService.open?(@channel) && @user&.tier == "free"
      }
    end

    # Drill detail objects: {code, label_key, params}. label_key = deterministic derivation
    # ("reason.<code downcased>") — clients resolve against their own bundle and hide unknown
    # keys (same defence as band label_key); no server-side copywriting here (legal-safe copy
    # ships with the i18n pass, not this contract PR).
    def reason_codes_detail_v2(tih)
      (tih&.reason_codes || []).filter_map do |c|
        code = c.is_a?(Hash) ? (c["code"] || c[:code]) : c
        next nil if code.blank?

        params = c.is_a?(Hash) ? (c["params"] || c[:params] || {}) : {}
        { code: code, label_key: "reason.#{code.to_s.downcase}", params: params }
      end
    end

    # v2 signal breakdown [{layer, source, kind, value}] from TIH.signal_breakdown. The v2 engine
    # currently persists {} (the L0/L2 per-signal trace is a follow-up on the persistence side) —
    # the key still ships with [] because the extension's CardLiveDrillData requires it.
    def signal_breakdown_v2(tih)
      breakdown = tih&.signal_breakdown
      return [] unless breakdown.is_a?(Hash) && breakdown.any?

      breakdown.filter_map do |key, data|
        next nil unless data.is_a?(Hash)

        {
          layer: data["layer"] || data[:layer],
          source: (data["source"] || data[:source] || key).to_s,
          kind: data["kind"] || data[:kind],
          value: (data["value"] || data[:value])&.to_f
        }
      end
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
        f_hat: tih.f_hat&.to_f,
        interval: { lo: tih.f_hat_lo&.to_f, hi: tih.f_hat_hi&.to_f }
      }
    end

    def band_payload(tih)
      unless tih&.band_row
        return { row: 5, color: "grey", label_key: "band.grey_insufficient",
                 tooltip_key: "band.tooltip.grey_insufficient", sub: nil }
      end

      {
        row: tih.band_row,
        color: tih.band_color,
        label_key: TrustIndex::V2::BandClassifier.label_key_for(tih.band_row),
        tooltip_key: TrustIndex::V2::BandClassifier.tooltip_key_for(tih.band_row),
        sub: tih.band_sub
      }
    end

    def latest_v2_ti
      @latest_v2_ti ||= @channel.trust_index_histories
                                .where(engine_version: "v2")
                                .order(calculated_at: :desc)
                                .first
    end

    def latest_ccv
      current_stream = @channel.streams.where(ended_at: nil).order(started_at: :desc).first
      return nil unless current_stream

      CcvSnapshot.where(stream: current_stream).order(timestamp: :desc).pick(:ccv_count)
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
