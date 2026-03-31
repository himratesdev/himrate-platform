# frozen_string_literal: true

# TASK-032 FR-005/011: ERV endpoint.
# GET /channels/:id/erv — ERV + confidence interval (tier-scoped).
# Guest: headline (ERV% + label). Free: + details. Premium: + breakdown + historical.
# ETag support (FR-011).

module Api
  module V1
    class ErvController < Api::BaseController
      before_action :authenticate_user_optional!
      before_action :set_channel

      # FR-005: GET /api/v1/channels/:id/erv
      def show
        authorize @channel, :show?

        latest_ti = @channel.trust_index_histories.order(calculated_at: :desc).first
        view = erv_view

        payload = build_erv_payload(latest_ti, view)

        # FR-011: ETag
        etag_value = Digest::MD5.hexdigest(payload.to_json)
        if stale?(etag: etag_value, public: view == :headline)
          render json: { data: payload }
        end
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

      def erv_view
        return :headline unless current_user

        policy = ChannelPolicy.new(current_user, @channel)
        if policy.send(:premium_access_for?, @channel)
          :full
        elsif channel_live? || PostStreamWindowService.open?(@channel)
          :details
        else
          :headline
        end
      end

      def build_erv_payload(ti, view)
        return cold_start_payload if ti.nil?

        erv_data = TrustIndex::ErvCalculator.compute(
          ti_score: ti.trust_index_score.to_f,
          ccv: ti.ccv.to_i,
          confidence: ti.confidence.to_f
        )

        payload = {
          erv_percent: erv_data[:erv_percent],
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

          # Range for confidence 0.3-0.6
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
        current_stream = @channel.streams.where(ended_at: nil).order(started_at: :desc).first
        stream = current_stream || @channel.streams.order(started_at: :desc).first
        return nil unless stream

        ChattersSnapshot.where(stream: stream).order(timestamp: :desc).pick(:auth_ratio)&.to_f
      end

      def historical_erv_7d
        recent_ti = @channel.trust_index_histories
                            .where("calculated_at >= ?", 7.days.ago)
                            .pluck(:erv_percent)
                            .compact

        return nil if recent_ti.empty?

        (recent_ti.sum / recent_ti.size).round(2)
      end

      def channel_live?
        @channel.streams.where(ended_at: nil).exists?
      end
    end
  end
end
