# frozen_string_literal: true

# TASK-032 FR-001/007/008/009/011/013: Trust endpoint.
# GET /api/v1/channels/:id/trust — TI + ERV + signals (tier-scoped).
# Guest (headline), Free (drill_down during live/18h), Premium (full).
# ETag support for conditional requests (FR-011).

module Api
  module V1
    class TrustController < Api::BaseController
      before_action :authenticate_user_optional!
      before_action :set_channel

      # FR-001: GET /api/v1/channels/:id/trust
      def show
        authorize @channel, :show?

        view = trust_view
        payload = build_trust_payload(view)

        # FR-011: ETag for conditional requests
        etag_value = Digest::MD5.hexdigest(payload.to_json)
        if stale?(etag: etag_value, public: view == :headline)
          render json: { data: payload }
        end
      end

      private

      def set_channel
        @channel = find_channel
      end

      # Reuse TASK-031 pattern: UUID / login / twitch_id
      def find_channel
        id = params[:channel_id] || params[:id]

        if params[:twitch_id].present?
          Channel.find_by!(twitch_id: params[:twitch_id])
        elsif params[:login].present?
          Channel.find_by!(login: params[:login])
        elsif id =~ /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i
          Channel.find(id)
        else
          Channel.find_by!(login: id)
        end
      end

      # View selection based on tier (extends TASK-031 ChannelPolicy#serializer_view)
      def trust_view
        return :headline unless current_user

        if premium_access_for_channel?
          :full
        elsif channel_live? || PostStreamWindowService.open?(@channel)
          :drill_down
        else
          :headline
        end
      end

      def build_trust_payload(view)
        latest_ti = latest_trust_index
        cold_start = cold_start_data

        payload = build_headline(latest_ti, cold_start)

        if view == :drill_down || view == :full
          payload.merge!(build_drill_down(latest_ti))
        end

        if view == :full
          payload.merge!(build_full)
        end

        payload
      end

      def build_headline(latest_ti, cold_start)
        erv_data = erv_from_ti(latest_ti)

        {
          channel_id: @channel.id,
          channel_login: @channel.login,
          ti_score: latest_ti&.trust_index_score&.to_f,
          classification: latest_ti&.classification,
          erv_percent: latest_ti&.erv_percent&.to_f,
          erv_count: erv_data[:erv_count],
          erv_label: erv_data[:label],
          erv_label_color: erv_data[:label_color],
          cold_start_status: cold_start[:status],
          confidence: latest_ti&.confidence&.to_f,
          confidence_display: erv_data[:confidence_display],
          is_live: channel_live?,
          ccv: latest_ccv,
          # FR-009: Streamer Rating in headline
          streamer_rating: streamer_rating_data,
          # FR-013: Category percentile
          category_avg_ti: category_avg_ti,
          percentile_in_category: percentile_in_category(latest_ti),
          calculated_at: latest_ti&.calculated_at&.iso8601
        }
      end

      def build_drill_down(latest_ti)
        {
          signal_breakdown: signal_breakdown_for_stream,
          post_stream_expires_at: PostStreamWindowService.expires_at(@channel)&.iso8601,
          post_stream_window_expired: !channel_live? && !PostStreamWindowService.open?(@channel) && current_user&.tier == "free"
        }
      end

      def build_full
        reputation = @channel.streamer_reputation
        rehabilitation = rehabilitation_data

        {
          streamer_reputation: reputation ? {
            growth_pattern_score: reputation.growth_pattern_score&.to_f,
            follower_quality_score: reputation.follower_quality_score&.to_f,
            engagement_consistency_score: reputation.engagement_consistency_score&.to_f
          } : nil,
          erv_breakdown: erv_breakdown,
          rehabilitation: rehabilitation,
          bot_raid_victim: bot_raid_victim?,
          ti_protected: bot_raid_victim?
        }
      end

      # --- Data helpers ---

      def latest_trust_index
        @latest_ti ||= @channel.trust_index_histories
                                .order(calculated_at: :desc)
                                .first
      end

      def latest_ccv
        current_stream = @channel.streams.where(ended_at: nil).order(started_at: :desc).first
        return nil unless current_stream

        CcvSnapshot.where(stream: current_stream)
                   .order(timestamp: :desc)
                   .pick(:ccv_count)
      end

      def cold_start_data
        stream_count = @channel.streams.where.not(ended_at: nil).count
        TrustIndex::ColdStartGuard.assess_hash(stream_count)
      end

      def erv_from_ti(ti)
        return { erv_count: nil, label: nil, label_color: nil, confidence_display: { type: "insufficient" } } unless ti

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

      # FR-009: Streamer Rating
      def streamer_rating_data
        rating = @channel.streamer_rating
        return nil unless rating

        {
          score: rating.rating_score.to_f,
          streams_count: rating.streams_count,
          classification: rating_classification(rating.rating_score.to_f)
        }
      end

      def rating_classification(score)
        case score
        when 80..100 then "trusted"
        when 50..79 then "needs_review"
        when 25..49 then "suspicious"
        else "fraudulent"
        end
      end

      # FR-013: Category benchmarks
      def category_avg_ti
        current_stream = @channel.streams.order(started_at: :desc).first
        category = current_stream&.game_name || "default"

        SignalConfiguration.value_for("trust_index", category, "category_avg_ti")
      rescue SignalConfiguration::ConfigurationMissing
        nil
      end

      def percentile_in_category(latest_ti)
        return nil unless latest_ti&.trust_index_score

        ti_score = latest_ti.trust_index_score.to_f
        current_stream = @channel.streams.order(started_at: :desc).first
        category = current_stream&.game_name

        return nil unless category

        # Subquery: latest TI per channel in this category
        latest_ti_per_channel = TrustIndexHistory
          .joins(channel: :streams)
          .where(streams: { game_name: category })
          .select("DISTINCT ON (trust_index_histories.channel_id) trust_index_histories.channel_id, trust_index_histories.trust_index_score")
          .order("trust_index_histories.channel_id, trust_index_histories.calculated_at DESC")

        # Count via subquery
        total = TrustIndexHistory.from(latest_ti_per_channel, :sub).count
        return nil if total < 50

        below = TrustIndexHistory.from(latest_ti_per_channel, :sub)
                                  .where("sub.trust_index_score < ?", ti_score)
                                  .count

        ((below.to_f / total) * 100).round(1)
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

      def rehabilitation_data
        ti = latest_trust_index
        return nil unless ti&.rehabilitation_penalty&.positive? || ti&.rehabilitation_bonus&.positive?

        {
          penalty: ti.rehabilitation_penalty.to_f,
          bonus: ti.rehabilitation_bonus.to_f,
          clean_streams: clean_streams_count,
          total_required: 15
        }
      end

      def clean_streams_count
        # Count streams after last incident where TI > threshold
        threshold = SignalConfiguration.value_for("trust_index", "default", "incident_threshold")
        last_incident = @channel.trust_index_histories
                                .where("trust_index_score < ?", threshold)
                                .order(calculated_at: :desc)
                                .first

        return 0 unless last_incident

        @channel.trust_index_histories
                .where("calculated_at > ?", last_incident.calculated_at)
                .where("trust_index_score >= ?", threshold)
                .count
      rescue SignalConfiguration::ConfigurationMissing
        0
      end

      def bot_raid_victim?
        current_stream = @channel.streams.order(started_at: :desc).first
        return false unless current_stream

        RaidAttribution.where(stream: current_stream, is_bot_raid: true)
                       .where.not(source_channel_id: @channel.id)
                       .exists?
      end

      def channel_live?
        @channel.streams.where(ended_at: nil).exists?
      end

      def premium_access_for_channel?
        policy = ChannelPolicy.new(current_user, @channel)
        policy.send(:premium_access_for?, @channel)
      end
    end
  end
end
