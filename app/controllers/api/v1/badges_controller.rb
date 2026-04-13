# frozen_string_literal: true

# TASK-035 FR-035: Public SVG badge endpoint.
# Separate controller to avoid auth filter inheritance issues.
# Public, no auth, cacheable 5min.

module Api
  module V1
    class BadgesController < ActionController::API
      # No Pundit, no auth — fully public endpoint

      # GET /api/v1/channels/:channel_id/badge.svg
      def show
        channel = Channel.find_by(id: params[:channel_id]) || Channel.find_by!(login: params[:channel_id])

        ti = channel.trust_index_histories.order(calculated_at: :desc).first
        ti_score = ti&.trust_index_score&.to_f&.round(0) || 0

        color = case ti_score
        when 80..100 then "#22c55e"
        when 50..79 then "#eab308"
        when 25..49 then "#f97316"
        else "#ef4444"
        end

        svg = <<~SVG
          <svg xmlns="http://www.w3.org/2000/svg" width="200" height="40">
            <rect width="100" height="40" rx="4" fill="#1f2937"/>
            <rect x="100" width="100" height="40" rx="4" fill="#{color}"/>
            <rect x="96" width="8" height="40" fill="#{color}"/>
            <text x="50" y="25" font-family="sans-serif" font-size="13" fill="white" text-anchor="middle">HimRate</text>
            <text x="150" y="25" font-family="sans-serif" font-size="13" fill="white" text-anchor="middle" font-weight="bold">TI #{ti_score}</text>
          </svg>
        SVG

        expires_in 5.minutes, public: true
        render plain: svg.strip, content_type: "image/svg+xml"
      rescue ActiveRecord::RecordNotFound
        render plain: "", status: :not_found
      end
    end
  end
end
