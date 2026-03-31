# frozen_string_literal: true

# TASK-032 FR-005: ERV endpoint. CR #1/#5/#7/#8/#10/#11.

module Api
  module V1
    class ErvController < Api::BaseController
      include Channelable

      before_action :authenticate_user_optional!
      before_action :set_channel

      def show
        authorize @channel, :show_erv?

        view = erv_view

        # CR #10: Redis cache 30s
        payload = Rails.cache.fetch("erv:#{@channel.id}:#{view}", expires_in: 30.seconds) do
          build_erv_payload(view)
        end

        # FR-011: ETag
        etag_value = Digest::MD5.hexdigest(payload.to_json)
        if stale?(etag: etag_value, public: view == :headline)
          render json: { data: payload }
        end
      end

      private

      def erv_view
        return :headline unless current_user

        policy = ChannelPolicy.new(current_user, @channel)
        if policy.premium_access?
          :full
        elsif @channel.live? || PostStreamWindowService.open?(@channel)
          :details
        else
          :headline
        end
      end

      def build_erv_payload(view)
        ti = @channel.trust_index_histories.order(calculated_at: :desc).first
        return cold_start_payload if ti.nil?

        erv_data = TrustIndex::ErvCalculator.compute(
          ti_score: ti.trust_index_score.to_f,
          ccv: ti.ccv.to_i,
          confidence: ti.confidence.to_f
        )

        # CR #1: i18n-aware label
        payload = {
          erv_percent: erv_data[:erv_percent]&.clamp(0.0, 100.0),
          erv_label: I18n.locale == :ru ? erv_data[:label] : erv_data[:label_en],
          erv_label_color: erv_data[:label_color]
        }

        if view == :details || view == :full
          payload.merge!(
            erv_count: erv_data[:erv_count],
            ccv: ti.ccv.to_i,
            confidence: ti.confidence&.to_f,
            confidence_display: erv_data[:confidence_display]
          )

          cd = erv_data[:confidence_display]
          if cd.is_a?(Hash) && cd[:type] == "range"
            payload[:erv_range_low] = cd[:low]
            payload[:erv_range_high] = cd[:high]
          end
        end

        if view == :full
          payload.merge!(
            bots_estimated: [ ti.ccv.to_i - (erv_data[:erv_count] || 0), 0 ].max,
            auth_percent: latest_auth_ratio,
            historical_erv_percent: historical_erv_7d
          )
        end

        payload
      end

      def cold_start_payload
        {
          erv_percent: nil,
          erv_label: nil,
          erv_label_color: nil,
          cold_start: true,
          message: I18n.t("erv.insufficient_data", default: "Insufficient data for ERV estimate")
        }
      end

      def latest_auth_ratio
        stream = @channel.streams.where(ended_at: nil).order(started_at: :desc).first ||
                 @channel.streams.order(started_at: :desc).first
        return nil unless stream

        ChattersSnapshot.where(stream: stream).order(timestamp: :desc).pick(:auth_ratio)&.to_f
      end

      def historical_erv_7d
        recent = @channel.trust_index_histories
                         .where("calculated_at >= ?", 7.days.ago)
                         .pluck(:erv_percent)
                         .compact

        return nil if recent.empty?

        (recent.sum / recent.size).round(2)
      end
    end
  end
end
