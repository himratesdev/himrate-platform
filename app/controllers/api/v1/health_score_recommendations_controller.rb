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

        DismissedRecommendation.create!(
          user_id: current_user.id,
          channel_id: @channel.id,
          rule_id: rule_id,
          dismissed_at: Time.current
        )

        invalidate_cache
        head :no_content
      rescue ActiveRecord::RecordNotUnique
        # Idempotent: already dismissed
        invalidate_cache
        head :no_content
      end

      private

      def valid_rule_id?(rule_id)
        return false if rule_id.blank?

        rule_id.match?(/\AR-\d{2}\z/) && RecommendationTemplate.exists?(rule_id: rule_id)
      end

      def invalidate_cache
        # Match any weights_version prefix for this channel
        Rails.cache.delete_matched("health_score:*:#{@channel.id}")
      rescue NotImplementedError
        # Redis without delete_matched support — fallback: invalidate known key patterns
        Rails.cache.delete("health_score:#{@channel.id}")
      end
    end
  end
end
