# frozen_string_literal: true

# TASK-038 FR-022..023: Dismiss recommendation endpoint.
# POST /api/v1/channels/:channel_id/health_score/recommendations/:rule_id/dismiss → 204
# Idempotent (duplicate returns 204). rule_id whitelist (400 on unknown).

module Api
  module V1
    class HealthScoreRecommendationsController < Api::BaseController
      include Channelable

      before_action :authenticate_user!
      before_action :set_channel

      def dismiss
        authorize @channel, :dismiss_recommendation?

        rule_id = params[:rule_id]
        unless valid_rule_id?(rule_id)
          render json: { error: "invalid_rule_id", rule_id: rule_id }, status: :bad_request
          return
        end

        DismissedRecommendation.find_or_create_by!(
          user_id: current_user.id,
          channel_id: @channel.id,
          rule_id: rule_id
        ) { |r| r.dismissed_at = Time.current }

        invalidate_cache
        head :no_content
      rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid
        # Idempotent: already dismissed
        invalidate_cache
        head :no_content
      end

      private

      def valid_rule_id?(rule_id)
        return false if rule_id.blank?

        rule_id.match?(/\AR-\d{2,}\z/) && RecommendationTemplate.enabled.exists?(rule_id: rule_id)
      end

      def invalidate_cache
        # Compute exact cache key (matches HealthScoresController#cache_key format)
        latest = HealthScore.where(channel_id: @channel.id).order(calculated_at: :desc).first
        category = latest&.category
        version = if category
          SignalConfiguration
            .where(signal_type: "health_score", category: category)
            .maximum(:updated_at)&.to_i || 0
        else
          0
        end
        Rails.cache.delete("health_score:cat_v#{version}:#{@channel.id}")
      end
    end
  end
end
