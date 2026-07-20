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
      # PR3b: v2 PSRs stop-write the retired scalars (nil) — enrich from the stream's final v2 TIH
      # (band/authenticity/interval live there, PSR = denormalized cache). v1 PSRs render as before.
      trust_index = if v2_engine?
        tih = final_v2_tih
        {
          erv: psr.erv_final,
          erv_interval: tih&.erv_lo ? { lo: tih.erv_lo, hi: tih.erv_hi } : nil,
          authenticity: tih&.authenticity&.to_f,
          band: tih&.band_row ? { row: tih.band_row, color: tih.band_color, sub: tih.band_sub } : nil,
          confirmed_anomaly: tih&.confirmed_anomaly,
          engine_version: "v2"
        }
      else
        {
          ti_score: psr.trust_index_final&.to_f,
          erv_percent: psr.erv_percent_final&.to_f&.clamp(0.0, 100.0),
          erv_count: psr.erv_final
        }
      end

      {
        stream: stream_detail,
        trust_index: trust_index,
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
      return build_assembled_v2 if v2_engine?

      ti = @stream.trust_index_histories.where(engine_version: "v1").order(calculated_at: :desc).first
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

    # v2 fallback (no PSR yet): read the final v2 TIH directly; ErvEstimate is retired (v2 writes
    # none) — the erv block comes from the same row.
    def build_assembled_v2
      ti = final_v2_tih

      {
        stream: stream_detail,
        trust_index: ti ? {
          erv: ti.erv,
          erv_interval: { lo: ti.erv_lo, hi: ti.erv_hi },
          authenticity: ti.authenticity&.to_f,
          band: ti.band_row ? { row: ti.band_row, color: ti.band_color, sub: ti.band_sub } : nil,
          confirmed_anomaly: ti.confirmed_anomaly,
          cold_start_tier: ti.cold_start_tier,
          confidence_marker: ti.confidence_marker,
          reason_codes: ti.reason_codes || [],
          engine_version: "v2"
        } : nil,
        signals: signals,
        chat_stats: chat_stats,
        anomalies: anomalies,
        ccv_timeline: ccv_timeline,
        raids: raids
      }
    end

    def final_v2_tih
      @final_v2_tih ||= @stream.trust_index_histories
                               .where(engine_version: "v2")
                               .order(calculated_at: :desc)
                               .first
    end

    def v2_engine?
      return @v2_engine if defined?(@v2_engine)

      @v2_engine =
        begin
          Flipper.enabled?(:ti_v2_engine)
        rescue StandardError
          false
        end
    end

    def stream_detail
      # PR-A1: peak_ccv / avg_ccv / duration_ms derived (columns dropped, single source).
      {
        id: @stream.id,
        started_at: @stream.started_at.iso8601,
        ended_at: @stream.ended_at&.iso8601,
        duration_ms: @stream.current_duration_ms,
        peak_ccv: @stream.current_peak_ccv,
        avg_ccv: @stream.current_avg_ccv,
        game_name: @stream.game_name,
        title: @stream.title,
        language: @stream.language,
        merge_status: @stream.merge_status,
        # CR #12: real parts count from DB
        merged_parts_count: @stream.merged_parts_count
      }
    end

    # BUG-TI-SIGNAL-BREAKDOWN (2026-06-01): read signals from latest TIH.signal_breakdown
    # JSON column. The `signals` PG table is dead-write since TrustIndex::Engine refactor.
    # Same fix pattern as Trust::ShowService + PostStreamWorker.
    def signals
      # PR3b: v2 rows carry no signal_breakdown — reason_codes (in trust_index above) replace it.
      return [] if v2_engine?

      tih = TrustIndexHistory.where(stream_id: @stream.id, engine_version: "v1").order(calculated_at: :desc).first
      return [] unless tih

      breakdown = tih.signal_breakdown
      return [] unless breakdown.is_a?(Hash)

      breakdown.map do |signal_type, data|
        next nil unless data.is_a?(Hash)
        {
          type: signal_type,
          value: data["value"]&.to_f,
          confidence: data["confidence"]&.to_f,
          weight: data["weight"]&.to_f,
          metadata: nil
        }
      end.compact
    end

    def chat_stats
      latest = ChattersSnapshot.where(stream: @stream).order(timestamp: :desc).first
      return nil unless latest

      {
        unique_chatters: latest.unique_chatters_count,
        total_messages: latest.total_messages_count,
        # TASK-251.6: auth_ratio suppressed (nil) — it's active-chatters/CCV (~0.01–0.08),
        # not the authenticated/present-chatters share this field implies; surfacing it
        # misleads (reads as mostly-bots). Re-enable with a present-chatters source (TASK-251.9).
        auth_ratio: nil
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
