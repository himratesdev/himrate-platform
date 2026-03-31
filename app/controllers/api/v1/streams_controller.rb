# frozen_string_literal: true

# TASK-032 FR-002/003/010/014: Streams + Report endpoints.
# GET /channels/:id/streams — paginated history (Premium/Business/Streamer own).
# GET /channels/:id/streams/:stream_id/report — post-stream drill-down.

module Api
  module V1
    class StreamsController < Api::BaseController
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

      # Redirect show to report for backward compat
      def show
        authenticate_user_optional!
        report
      end

      # FR-003/010/014: GET /api/v1/channels/:id/streams/:stream_id/report
      def report
        stream = @channel.streams.find(params[:stream_id] || params[:id])
        authorize @channel, :show?
        authorize_report!(stream)
        return if performed?

        # FR-014: Primary source = post_stream_reports, fallback to assembly
        psr = PostStreamReport.find_by(stream: stream)

        payload = if psr
                    build_report_from_psr(stream, psr)
        else
                    build_report_assembled(stream)
        end

        render json: { data: payload }
      end

      private

      def set_channel
        id = params[:channel_id]
        @channel = if id =~ /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i
                     Channel.find(id)
        else
                     Channel.find_by!(login: id)
        end
      end

      def authorize_report!(stream)
        # Free: only if post-stream window open or live
        # Premium/Business: always for tracked
        # Streamer: always for own
        if current_user.nil?
          render json: { error: "UNAUTHORIZED", message: I18n.t("auth.errors.bearer_required") }, status: :unauthorized
          return
        end

        policy = ChannelPolicy.new(current_user, @channel)

        if policy.send(:premium_access_for?, @channel)
          # Premium/Business/Streamer own — always
          return
        end

        # Free — check TIME-lock
        if stream.ended_at.nil?
          # Live stream — drill-down allowed for registered
          return
        end

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
          erv_percent: ti&.erv_percent&.to_f,
          classification: ti&.classification,
          parts_count: stream.merge_status == "merged" ? 2 : 1
        }
      end

      # FR-014: Build from pre-generated post_stream_reports
      def build_report_from_psr(stream, psr)
        {
          stream: stream_detail(stream),
          trust_index: {
            ti_score: psr.trust_index_final&.to_f,
            erv_percent: psr.erv_percent_final&.to_f,
            erv_count: psr.erv_final
          },
          signals_summary: psr.signals_summary,
          chat_stats: {
            ccv_peak: psr.ccv_peak,
            ccv_avg: psr.ccv_avg,
            duration_ms: psr.duration_ms
          },
          anomalies: psr.anomalies,
          # FR-010: CCV Timeline
          ccv_timeline: ccv_timeline_for(stream),
          raids: raids_for(stream)
        }
      end

      # Fallback: assemble from individual tables
      def build_report_assembled(stream)
        ti = stream.trust_index_histories.order(calculated_at: :desc).first
        erv = ErvEstimate.where(stream: stream).order(timestamp: :desc).first

        {
          stream: stream_detail(stream),
          trust_index: ti ? {
            ti_score: ti.trust_index_score.to_f,
            erv_percent: ti.erv_percent&.to_f,
            erv_count: ti.ccv.to_i > 0 ? (ti.ccv * ti.trust_index_score.to_f / 100.0).round : nil,
            classification: ti.classification,
            cold_start_status: ti.cold_start_status,
            confidence: ti.confidence&.to_f,
            signal_breakdown: ti.signal_breakdown
          } : nil,
          erv: erv ? {
            erv_count: erv.erv_count,
            erv_percent: erv.erv_percent.to_f,
            confidence: erv.confidence&.to_f,
            label: erv.label
          } : nil,
          signals: signals_for(stream),
          chat_stats: chat_stats_for(stream),
          anomalies: anomalies_for(stream),
          # FR-010: CCV Timeline
          ccv_timeline: ccv_timeline_for(stream),
          raids: raids_for(stream)
        }
      end

      def stream_detail(stream)
        {
          id: stream.id,
          started_at: stream.started_at.iso8601,
          ended_at: stream.ended_at&.iso8601,
          duration_ms: stream.duration_ms,
          peak_ccv: stream.peak_ccv,
          avg_ccv: stream.avg_ccv,
          game_name: stream.game_name,
          title: stream.title,
          language: stream.language,
          merge_status: stream.merge_status
        }
      end

      def signals_for(stream)
        TiSignal.where(stream: stream)
              .select("DISTINCT ON (signal_type) signal_type, value, confidence, weight_in_ti, metadata, timestamp")
              .order(:signal_type, timestamp: :desc)
              .map do |sig|
          {
            type: sig.signal_type,
            value: sig.value.to_f,
            confidence: sig.confidence&.to_f,
            weight: sig.weight_in_ti&.to_f,
            metadata: sig.metadata
          }
        end
      end

      def chat_stats_for(stream)
        latest = ChattersSnapshot.where(stream: stream).order(timestamp: :desc).first
        return nil unless latest

        {
          unique_chatters: latest.unique_chatters_count,
          total_messages: latest.total_messages_count,
          auth_ratio: latest.auth_ratio&.to_f
        }
      end

      def anomalies_for(stream)
        Anomaly.where(stream: stream).order(timestamp: :asc).map do |a|
          {
            type: a.anomaly_type,
            cause: a.cause,
            ccv_impact: a.ccv_impact,
            confidence: a.confidence&.to_f,
            timestamp: a.timestamp.iso8601,
            details: a.details
          }
        end
      end

      # FR-010: CCV Timeline with downsampling for long streams (max 500 points)
      def ccv_timeline_for(stream)
        snapshots = CcvSnapshot.where(stream: stream).order(timestamp: :asc)
        total = snapshots.count

        if total <= 500
          snapshots.map do |s|
            {
              timestamp: s.timestamp.iso8601,
              ccv: s.ccv_count,
              real_viewers: s.real_viewers_estimate
            }
          end
        else
          # Downsampling: group into 500 buckets, avg each
          bucket_size = (total.to_f / 500).ceil
          snapshots.each_slice(bucket_size).map do |bucket|
            {
              timestamp: bucket.first.timestamp.iso8601,
              ccv: (bucket.sum(&:ccv_count).to_f / bucket.size).round,
              real_viewers: bucket.compact_blank.any? ? (bucket.filter_map(&:real_viewers_estimate).sum.to_f / bucket.filter_map(&:real_viewers_estimate).size).round : nil
            }
          end
        end
      end

      def raids_for(stream)
        RaidAttribution.where(stream: stream).order(timestamp: :asc).map do |r|
          {
            source_channel_id: r.source_channel_id,
            viewers: r.raid_viewers_count,
            bot_score: r.bot_score&.to_f,
            is_bot_raid: r.is_bot_raid,
            timestamp: r.timestamp.iso8601,
            signal_scores: r.signal_scores
          }
        end
      end
    end
  end
end
