# frozen_string_literal: true

# TASK-032 FR-002/003: Streams + Report endpoints.
# CR #5: Channelable concern. CR #6: Service objects. CR #13: proper routing.

module Api
  module V1
    class StreamsController < Api::BaseController
      include Channelable

      before_action :set_channel
      before_action :authenticate_user!, only: %i[index report]

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
      # PG WARNING #2: Paywall via Pundit view_report? (not controller logic)
      def report
        stream = @channel.streams.find(params[:stream_id] || params[:id])
        authorize @channel, :view_report?

        payload = Streams::ReportService.new(stream: stream, channel: @channel).call

        render json: { data: payload }
      end

      private

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
          merged_parts_count: stream.merged_parts_count
        }
      end
    end
  end
end
