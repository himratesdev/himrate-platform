# frozen_string_literal: true

# TASK-032 FR-004: Health Score endpoint.
# GET /channels/:id/health-score — HS + 5 components + trend.
# Access: Streamer own (data exchange), Premium tracked, Business.

module Api
  module V1
    class HealthScoresController < Api::BaseController
      before_action :authenticate_user!
      before_action :set_channel

      # FR-004: GET /api/v1/channels/:id/health-score
      def show
        authorize @channel, :view_health_score?

        latest_hs = HealthScore.where(channel: @channel).order(calculated_at: :desc).first
        stream_count = @channel.streams.where.not(ended_at: nil).count
        cold_start_tier = health_score_cold_start_tier(stream_count)

        payload = {
          health_score: latest_hs&.health_score&.to_f,
          label: hs_label(latest_hs&.health_score&.to_f),
          label_color: hs_label_color(latest_hs&.health_score&.to_f),
          confidence_badge: latest_hs&.confidence_level || cold_start_tier,
          stream_count: stream_count,
          cold_start_tier: cold_start_tier,
          components: {
            ti: latest_hs&.ti_component&.to_f,
            stability: latest_hs&.stability_component&.to_f,
            engagement: latest_hs&.engagement_component&.to_f,
            growth: latest_hs&.growth_component&.to_f,
            consistency: latest_hs&.consistency_component&.to_f
          },
          calculated_at: latest_hs&.calculated_at&.iso8601
        }

        # Trend: Premium gets 30d, Business gets all periods
        if effective_business?
          payload[:trend_30d] = hs_trend(30)
          payload[:trend_60d] = hs_trend(60)
          payload[:trend_90d] = hs_trend(90)
          payload[:trend_365d] = hs_trend(365)
        elsif premium_access_for_channel?
          payload[:trend_30d] = hs_trend(30)
        end

        render json: { data: payload }
      end

      private

      def set_channel
        id = params[:channel_id] || params[:id]
        @channel = if id =~ /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i
                     Channel.find(id)
        else
                     Channel.find_by!(login: id)
        end
      end

      def hs_trend(days)
        HealthScore.where(channel: @channel)
                   .where("calculated_at >= ?", days.days.ago)
                   .order(calculated_at: :asc)
                   .pluck(:calculated_at, :health_score)
                   .map { |at, hs| { date: at.to_date.iso8601, health_score: hs.to_f } }
      end

      def health_score_cold_start_tier(stream_count)
        case stream_count
        when 0..2 then "insufficient"
        when 3..6 then "provisional_low"
        when 7..9 then "provisional"
        when 10..29 then "full"
        else "deep"
        end
      end

      def hs_label(score)
        return nil unless score

        case score.round
        when 80..100 then I18n.t("health_score.labels.excellent", default: "Excellent")
        when 60..79 then I18n.t("health_score.labels.good", default: "Good")
        when 40..59 then I18n.t("health_score.labels.average", default: "Average")
        when 20..39 then I18n.t("health_score.labels.below_average", default: "Below Average")
        else I18n.t("health_score.labels.poor", default: "Poor")
        end
      end

      def hs_label_color(score)
        return nil unless score

        case score.round
        when 80..100 then "green"
        when 60..79 then "light_green"
        when 40..59 then "yellow"
        when 20..39 then "orange"
        else "red"
        end
      end

      def effective_business?
        policy = ChannelPolicy.new(current_user, @channel)
        policy.send(:effective_business?)
      end

      def premium_access_for_channel?
        policy = ChannelPolicy.new(current_user, @channel)
        policy.send(:premium_access_for?, @channel)
      end
    end
  end
end
