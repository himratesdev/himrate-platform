# frozen_string_literal: true

module Brand
  # Screen 21 — Brand Streamer Card. Independent 30-day track-record verification of a streamer
  # before a deal ("то же, что видит зритель, но за окно 30 дней, а не live-снимок"). Composes
  # EXISTING production engine — never mocks. Every block is real or derived-from-real; anything the
  # engine cannot back is listed in `deferred` (frontend hides those design blocks) rather than
  # faked. Bounded per-channel reads (≤30 daily rows / 1 TIH / 6h-cached reputation / ≤50 anomalies)
  # → scale-safe. Compute-on-read, no schema.
  #
  # Grounded on live DSV (lk-dsv-probe, 2026-07-19):
  #   - TrendsDailyAggregate.botted_fraction is NULL → bot-correction derived from ccv_avg × erv% only.
  #   - Anomaly is keyed by stream_id (no channel_id) → join through streams.
  #   - signal_breakdown has 11-12 keys, varies per channel → expose only present signals.
  #   - per-signal value semantics are non-uniform (auth_ratio high=good, known_bot_match low=good) →
  #     no server-side norm/attention verdict here; expose raw + real overall classification (ADR DEC-3).
  class StreamerCardService
    WINDOW_DAYS = 30
    ANOMALY_LIMIT = 50
    OPEN_DISPUTE_STATUSES = %w[pending reviewing].freeze
    Result = Struct.new(:ok, :error, :payload, keyword_init: true)

    # RU labels for the 12 canonical TI signals (design 21 layer-2 names). Only present signals render.
    SIGNAL_LABELS_RU = {
      "auth_ratio" => "Соотношение подлинных аккаунтов",
      "chatter_ccv_ratio" => "Соотношение чат / зрители",
      "chat_behavior" => "Поведение чата",
      "ccv_step_function" => "Ступенчатые скачки онлайна",
      "ccv_tier_clustering" => "Кластеризация онлайна",
      "ccv_chat_correlation" => "Корреляция чата и онлайна",
      "cross_channel_presence" => "Пересечение аудитории каналов",
      "temporal_cross_channel" => "Синхронные всплески",
      "known_bot_match" => "Совпадение с известными ботами",
      "raid_attribution" => "Атрибуция рейдов",
      "account_profile_scoring" => "Профили аккаунтов",
      "channel_protection_score" => "Защита канала"
    }.freeze

    # Design blocks with NO real engine source — surfaced honestly so frontend hides them, never mocked.
    DEFERRED = %w[
      traffic_source_split audience_geography repeat_viewer_pct median_chat_ratio_30d
      session_retention social_platforms pdf_export add_to_campaign dispute_write
      overlap_in_card period_depth_history layer2_per_signal_verdict
    ].freeze

    def initialize(login:)
      @login = login.to_s.strip.downcase
    end

    def call
      return Result.new(ok: false, error: "CHANNEL_NOT_FOUND") if @login.blank?

      channel = Channel.active.find_by("lower(login) = ?", @login)
      return Result.new(ok: false, error: "CHANNEL_NOT_FOUND") unless channel

      Result.new(ok: true, payload: build(channel))
    end

    private

    def build(channel)
      # Window metadata + layer1 both come from the shared Brand::AudienceWindow — the same 30-day
      # aggregate Brand Compare (#23) uses, so "real viewers" can never diverge between surfaces.
      # Window lives at top-level data.window per SRS §4A (present even for a cold-start channel).
      win = Brand::AudienceWindow.new(channel, days: WINDOW_DAYS)
      {
        channel: channel_block(channel),
        window: win.window_meta,
        layer1_real_audience: win.audience,
        layer2_authenticity: layer2(channel),
        layer3_reputation: layer3(channel),
        layer5_anomalies: layer5(channel),
        deferred: DEFERRED
      }
    end

    def channel_block(channel)
      stream = channel.streams.order(started_at: :desc).first
      {
        login: channel.login,
        display_name: channel.display_name,
        avatar_url: channel.profile_image_url,
        broadcaster_type: channel.broadcaster_type,
        followers_count: channel.followers_total,
        category: stream&.game_name,
        language: stream&.language
      }
    end

    # Layer 2 — authenticity signals from the latest Trust Index. Raw per-signal breakdown + the real
    # overall classification (the engine's actual verdict). Per-signal norm/attention verdict deferred
    # (non-uniform value semantics — ADR DEC-3). Only signals actually present render.
    def layer2(channel)
      return layer2_v2(channel) if v2_engine?

      tih = TrustIndexHistory.where(channel_id: channel.id, engine_version: "v1").order(calculated_at: :desc).first
      return { available: false } if tih.nil? || tih.signal_breakdown.blank?

      checks = tih.signal_breakdown.filter_map do |key, v|
        next unless v.is_a?(Hash)
        value = fetch(v, "value")
        next if value.nil?

        {
          signal: key,
          label_ru: SIGNAL_LABELS_RU[key] || key,
          value: value.to_f,
          confidence: fetch(v, "confidence")&.to_f,
          weight: fetch(v, "weight")&.to_f,
          contribution: fetch(v, "contribution")&.to_f
        }
      end

      {
        available: true,
        classification: tih.classification,
        ti_score: tih.trust_index_score&.to_f,
        checks_total: checks.size,
        checks: checks,
        calculated_at: tih.calculated_at&.iso8601,
        basis: "trust_index_history.signal_breakdown"
      }
    end

    # PR3b (T1-074, M11a): v2 layer2 — the 6-row band + reason_codes replace the retired
    # 14-signal breakdown/classification (legal-safe: engine-emitted codes, no ti_score scalar).
    def layer2_v2(channel)
      tih = TrustIndexHistory.where(channel_id: channel.id, engine_version: "v2").order(calculated_at: :desc).first
      return { available: false } if tih.nil?

      {
        available: true,
        band: {
          row: tih.band_row, color: tih.band_color,
          label_key: TrustIndex::V2::BandClassifier.label_key_for(tih.band_row),
          sub: tih.band_sub
        },
        authenticity: tih.authenticity&.to_f,
        erv: tih.erv,
        erv_interval: { lo: tih.erv_lo, hi: tih.erv_hi },
        reason_codes: tih.reason_codes || [],
        confirmed_anomaly: tih.confirmed_anomaly,
        cold_start_tier: tih.cold_start_tier,
        confidence_marker: tih.confidence_marker,
        calculated_at: tih.calculated_at&.iso8601,
        basis: "trust_index_history.v2"
      }
    end

    def v2_engine?
      return @v2_engine if defined?(@v2_engine)

      @v2_engine =
        begin
          Flipper.enabled?(:ti_v2_engine)
        rescue StandardError
          false
        end
    end

    # Layer 3 — reputation band + trend + trajectory (the free trust-summary, T1-065) + read-only
    # dispute status. HistoryService returns honest-empty (band nil) for cold-start.
    def layer3(channel)
      rep = Reputation::HistoryService.cached_for(channel)
      current = rep[:current] || {}
      {
        band: current[:band],
        band_label_ru: Brand::ReputationBands.label_ru(current[:band]),
        tier: current[:tier],
        stream_count: current[:stream_count],
        trend: rep[:trend],
        trajectory: rep[:real_audience_trajectory],
        components: components_block(rep),
        dispute: latest_open_dispute(channel)
      }
    end

    # SRS §4A shape: the 3 public reputation components; follower_quality carries the honest stub flag.
    def components_block(rep)
      latest = rep[:components_history]&.last || {}
      {
        growth_pattern: latest[:growth_pattern],
        engagement_consistency: latest[:engagement_consistency],
        follower_quality: { score: latest[:follower_quality], stubbed: rep[:follower_quality_stubbed] }
      }
    end

    def latest_open_dispute(channel)
      dispute = ScoreDispute
                .where(channel_id: channel.id, resolution_status: OPEN_DISPUTE_STATUSES)
                .order(submitted_at: :desc)
                .first
      return nil unless dispute

      { status: dispute.resolution_status, dispute_id: dispute.id, submitted_at: dispute.submitted_at&.iso8601 }
    end

    # Layer 5 — anomalies over the window. Anomaly is keyed by stream_id (DSV) → join through streams.
    def layer5(channel)
      Anomaly
        .joins(:stream)
        .where(streams: { channel_id: channel.id })
        .where("anomalies.timestamp > ?", window_from)
        .includes(:anomaly_attributions)
        .order("anomalies.timestamp DESC")
        .limit(ANOMALY_LIMIT)
        .map do |a|
          top = a.anomaly_attributions.max_by { |att| att.confidence.to_f }
          {
            at: a.timestamp&.iso8601,
            type: a.anomaly_type,
            cause: a.cause,
            ccv_impact: a.ccv_impact,
            attribution: top && { source: top.source, confidence: top.confidence&.to_f }
          }
        end
    end

    def window_from
      @window_from ||= WINDOW_DAYS.days.ago.to_date
    end

    def fetch(hash, key)
      hash[key].nil? ? hash[key.to_sym] : hash[key]
    end
  end
end
