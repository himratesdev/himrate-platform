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
      latest_ti = latest_trust_index
      cold_start = cold_start_data

      payload = build_headline(latest_ti, cold_start)

      if @view == :drill_down || @view == :full
        payload.merge!(build_drill_down(latest_ti))
        # TASK-085 FR-008 (ADR-085 D-4 OVERRIDE): anomaly_alerts gated за :drill_down/:full —
        # NOT :headline (Pundit contract preserved, no anonymous data leak).
        payload[:anomaly_alerts] = AnomalyAlertsPresenter.new(channel: @channel).call
      end

      if @view == :full
        payload.merge!(build_full)
      end

      payload
    end

    private

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

      {
        streamer_reputation: reputation ? {
          growth_pattern_score: reputation.growth_pattern_score&.to_f,
          follower_quality_score: reputation.follower_quality_score&.to_f,
          engagement_consistency_score: reputation.engagement_consistency_score&.to_f
        } : nil,
        erv_breakdown: erv_breakdown,
        bot_raid_victim: bot_raid_victim?,
        ti_protected: bot_raid_victim?,
        # TASK-035 FR-033: top countries from chatters demographic data
        top_countries: top_countries_data
      }
    end

    def latest_trust_index
      @latest_ti ||= @channel.trust_index_histories
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

    def signal_breakdown_for_stream
      current_stream = @channel.streams.order(started_at: :desc).first
      return [] unless current_stream

      TiSignal.where(stream: current_stream)
              .select("DISTINCT ON (signal_type) signal_type, value, confidence, weight_in_ti, metadata, timestamp")
              .order(:signal_type, timestamp: :desc)
              .map do |sig|
        {
          type: sig.signal_type,
          value: sig.value.to_f,
          confidence: sig.confidence&.to_f,
          weight: sig.weight_in_ti&.to_f,
          contribution: (sig.value.to_f * (sig.weight_in_ti || 0).to_f).round(4),
          metadata: sig.metadata
        }
      end
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
  end
end
