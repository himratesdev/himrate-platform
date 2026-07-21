# frozen_string_literal: true

# TASK-032 FR-002/003: Streams + Report endpoints.
# CR #5: Channelable concern. CR #6: Service objects. CR #13: proper routing.

module Api
  module V1
    class StreamsController < Api::BaseController
      include Channelable

      before_action :set_channel
      before_action :authenticate_user!, only: %i[index report latest_summary]

      # FR-002: GET /api/v1/channels/:id/streams — stream history
      def index
        authorize @channel, :view_streams?

        # CR-iter1 MF-1 (PR-A1): preload :post_stream_report so Stream#current_peak_ccv /
        # current_avg_ccv / current_duration_ms (called per-row from stream_summary) hit the
        # already-loaded association rather than firing one SELECT per stream. Without this,
        # rendering 50 streams = 50 PSR SELECTs — N+1 regression vs the pre-PR-A1 column read.
        streams = @channel.streams
                          .where.not(ended_at: nil)
                          .includes(:trust_index_histories, :post_stream_report)
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

      # TASK-085 FR-001..006: GET /api/v1/channels/:id/streams/latest/summary
      # Returns last completed stream summary с PostStreamReport data (joined existing tables).
      # Pundit ChannelPolicy#view_latest_stream_summary? gates: Premium/Business/Streamer own,
      # OR Free + post_stream_window open (18h). Guest → 401 via authenticate_user! before Pundit.
      #
      # PG W-3: Flipper kill-switch :stream_summary_endpoint per CLAUDE.md "Feature flags для
      # production рисков". Default ON (FlipperDefaults::ALL_FLAGS auto-enable on boot). Disable
      # via Flipper.disable(:stream_summary_endpoint) для emergency rollback без revert+deploy.
      def latest_summary
        unless Flipper.enabled?(:stream_summary_endpoint, current_user)
          skip_authorization
          render json: { error: { code: "FEATURE_DISABLED" } }, status: :service_unavailable
          return
        end

        authorize @channel, :view_latest_stream_summary?

        result = Streams::LatestSummaryService.new(channel: @channel).call

        if result == Streams::LatestSummaryService::NOT_FOUND
          render json: { error: { code: "STREAM_NOT_FOUND" } }, status: :not_found
          return
        end

        render json: result
      end

      private

      # PR3b (T1-074, M1): engine-aware — Ruby-side engine pick preserves the preload (no N+1).
      def stream_summary(stream)
        engine = v2_engine? ? "v2" : "v1"
        ti = stream.trust_index_histories.select { |t| t.engine_version == engine }.max_by(&:calculated_at)

        # PR-A1: peak_ccv / avg_ccv / duration_ms derived (columns dropped, single source).
        base = {
          id: stream.id,
          started_at: stream.started_at.iso8601,
          ended_at: stream.ended_at&.iso8601,
          duration_ms: stream.current_duration_ms,
          peak_ccv: stream.current_peak_ccv,
          avg_ccv: stream.current_avg_ccv,
          game_name: stream.game_name,
          title: stream.title,
          # CR #12: real parts count
          merged_parts_count: stream.merged_parts_count
        }
        if v2_engine?
          # Surface-audit sweep: band_row + canonical label_key + grey fallback + engine_version
          # (the dual-shape consumers rely on engine_version to branch).
          base.merge(
            erv: ti&.erv,
            authenticity: ti&.authenticity&.to_f,
            band_row: ti&.band_row,
            label_key: TrustIndex::V2::BandClassifier.label_key_for(ti&.band_row),
            band_color: ti&.band_color || "grey",
            confirmed_anomaly: ti&.confirmed_anomaly,
            engine_version: "v2"
          )
        else
          base.merge(
            ti_score: ti&.trust_index_score&.to_f,
            erv_percent: ti&.erv_percent&.to_f&.clamp(0.0, 100.0),
            classification: ti&.classification
          )
        end
      end

      def v2_engine?
        Flipper.enabled?(:ti_v2_engine)
      rescue StandardError
        false
      end
    end
  end
end
