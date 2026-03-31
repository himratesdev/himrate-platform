# frozen_string_literal: true

# TASK-032 FR-002/003: Streams + Report endpoints.
# CR #5: Channelable concern. CR #6: Service objects. CR #13: proper routing.

module Api
  module V1
    class StreamsController < Api::BaseController
      include Channelable

      before_action :set_channel
      before_action :authenticate_user!, only: :index
      before_action :authenticate_user_optional!, only: :report

      # FR-002: GET /api/v1/channels/:id/streams — stream history
      def index
        authorize @channel, :view_streams?

        streams = @channel.streams
                          .where.not(ended_at: nil)
                          .includes(:trust_index_histories)
                          .order(started_at: :desc)

        page = [ (params[:page] || 1).to_i, 1 ].max
        per_page = [ (params[:per_page] || 20).to_i, 50 ].min
        total = streams.count
        paginated = streams.offset((page - 1) * per_page).limit(per_page)

        data = paginated.map { |stream| stream_summary(stream) }

        render json: {
          data: data,
          meta: { page: page, per_page: per_page, total: total, total_pages: (total.to_f / per_page).ceil }
        }
      end

      # FR-003: GET /api/v1/channels/:id/streams/:stream_id/report
      def report
        stream = @channel.streams.find(params[:stream_id] || params[:id])
        authorize @channel, :show?
        authorize_report_access!(stream)
        return if performed?

        payload = Streams::ReportService.new(stream: stream, channel: @channel).call

        render json: { data: payload }
      end

      private

      # CR #13: authorize_report_access! with early return pattern
      def authorize_report_access!(stream)
        if current_user.nil?
          render json: { error: "UNAUTHORIZED", message: I18n.t("auth.errors.bearer_required") }, status: :unauthorized
          return
        end

        policy = ChannelPolicy.new(current_user, @channel)
        return if policy.premium_access?

        # Live stream — drill-down allowed for registered
        return if stream.ended_at.nil?

        # Free — check TIME-lock
        unless PostStreamWindowService.open?(@channel)
          render json: {
            error: "POST_STREAM_WINDOW_EXPIRED",
            message: I18n.t("streams.errors.window_expired",
              default: "Detailed analytics for this stream are no longer available"),
            cta: { action: "subscribe", label: I18n.t("pundit.cta.start_tracking") }
          }, status: :forbidden
        end
      end

      def stream_summary(stream)
        ti = stream.trust_index_histories.max_by(&:calculated_at)

        {
          id: stream.id,
          started_at: stream.started_at.iso8601,
          ended_at: stream.ended_at&.iso8601,
          duration_ms: stream.duration_ms,
          peak_ccv: stream.peak_ccv,
          avg_ccv: stream.avg_ccv,
          game_name: stream.game_name,
          title: stream.title,
          ti_score: ti&.trust_index_score&.to_f,
          erv_percent: ti&.erv_percent&.to_f&.clamp(0.0, 100.0),
          classification: ti&.classification,
          # CR #12: real parts count
          merged_parts_count: stream.respond_to?(:merged_parts_count) ? stream.merged_parts_count : 1
        }
      end
    end
  end
end
