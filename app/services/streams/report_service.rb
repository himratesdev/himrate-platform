# frozen_string_literal: true

# TASK-032 CR #6: Service object for stream report data assembly.

module Streams
  class ReportService
    def initialize(stream:, channel:)
      @stream = stream
      @channel = channel
    end

    def call
      # FR-014: Primary source = post_stream_reports, fallback to assembly
      psr = PostStreamReport.find_by(stream: @stream)

      if psr
        build_from_psr(psr)
      else
        build_assembled
      end
    end

    private

    def build_from_psr(psr)
      {
        stream: stream_detail,
        trust_index: {
          ti_score: psr.trust_index_final&.to_f,
          erv_percent: psr.erv_percent_final&.to_f&.clamp(0.0, 100.0),
          erv_count: psr.erv_final
        },
        signals_summary: psr.signals_summary,
        chat_stats: {
          ccv_peak: psr.ccv_peak,
          ccv_avg: psr.ccv_avg,
          duration_ms: psr.duration_ms
        },
        anomalies: psr.anomalies,
        ccv_timeline: ccv_timeline,
        raids: raids
      }
    end

    def build_assembled
      ti = @stream.trust_index_histories.order(calculated_at: :desc).first
      erv = ErvEstimate.where(stream: @stream).order(timestamp: :desc).first

      {
        stream: stream_detail,
        trust_index: ti ? {
          ti_score: ti.trust_index_score.to_f,
          erv_percent: ti.erv_percent&.to_f&.clamp(0.0, 100.0),
          erv_count: ti.ccv.to_i > 0 ? (ti.ccv * ti.trust_index_score.to_f / 100.0).round : nil,
          classification: ti.classification,
          cold_start_status: ti.cold_start_status,
          confidence: ti.confidence&.to_f,
          signal_breakdown: ti.signal_breakdown
        } : nil,
        erv: erv ? {
          erv_count: erv.erv_count,
          erv_percent: erv.erv_percent.to_f.clamp(0.0, 100.0),
          confidence: erv.confidence&.to_f,
          label: erv.label
        } : nil,
        signals: signals,
        chat_stats: chat_stats,
        anomalies: anomalies,
        ccv_timeline: ccv_timeline,
        raids: raids
      }
    end

    def stream_detail
      {
        id: @stream.id,
        started_at: @stream.started_at.iso8601,
        ended_at: @stream.ended_at&.iso8601,
        duration_ms: @stream.duration_ms,
        peak_ccv: @stream.peak_ccv,
        avg_ccv: @stream.avg_ccv,
        game_name: @stream.game_name,
        title: @stream.title,
        language: @stream.language,
        merge_status: @stream.merge_status,
        # CR #12: real parts count from DB
        merged_parts_count: @stream.merged_parts_count
      }
    end

    def signals
      TiSignal.where(stream: @stream)
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

    def chat_stats
      latest = ChattersSnapshot.where(stream: @stream).order(timestamp: :desc).first
      return nil unless latest

      {
        unique_chatters: latest.unique_chatters_count,
        total_messages: latest.total_messages_count,
        auth_ratio: latest.auth_ratio&.to_f
      }
    end

    def anomalies
      Anomaly.where(stream: @stream).order(timestamp: :asc).map do |a|
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

    # FR-010: CCV Timeline with downsampling (max 500 points). CR #3: no division by zero.
    def ccv_timeline
      snapshots = CcvSnapshot.where(stream: @stream).order(timestamp: :asc)
      total = snapshots.count
      return [] if total.zero?

      if total <= 500
        snapshots.map { |s| timeline_point(s) }
      else
        bucket_size = (total.to_f / 500).ceil
        snapshots.each_slice(bucket_size).map do |bucket|
          real_estimates = bucket.filter_map(&:real_viewers_estimate)
          {
            timestamp: bucket.first.timestamp.iso8601,
            ccv: (bucket.sum(&:ccv_count).to_f / bucket.size).round,
            real_viewers: real_estimates.any? ? (real_estimates.sum.to_f / real_estimates.size).round : nil
          }
        end
      end
    end

    def timeline_point(snapshot)
      {
        timestamp: snapshot.timestamp.iso8601,
        ccv: snapshot.ccv_count,
        real_viewers: snapshot.real_viewers_estimate
      }
    end

    def raids
      RaidAttribution.where(stream: @stream).order(timestamp: :asc).map do |r|
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
