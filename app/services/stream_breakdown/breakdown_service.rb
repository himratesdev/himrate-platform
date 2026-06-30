# frozen_string_literal: true

# T2-020 StreamBreakdown INC-1: composes the per-stream «Разбор эфира» payload — the deep,
# event-centric drill-down behind the channel-card's "Подробнее". Free layer-2 data for the viewer
# (access-model v2): per-minute real/fake timeline + chat funnel + auth-ratio series + the stream's
# anomaly events (reusing Trust::AnomalyAlertsPresenter, scoped to this stream, full history).
#
# INC-1 scope = honest real-data signals (timeline / funnel / auth-series / anomalies). The 7-metric
# "why fake" comparison with expected-baseline grey ("ждали +N") and the account-age / cross-channel
# distribution tabs need calibrated baselines — those ship in INC-2/INC-3 (no fabricated baselines here).
module StreamBreakdown
  class BreakdownService
    def initialize(stream:, channel:)
      @stream = stream
      @channel = channel
    end

    def call
      {
        stream: stream_meta,
        verdict: verdict,
        timeline: TimelineService.new(stream: @stream).call,
        funnel: FunnelService.new(stream: @stream).call,
        auth_series: AuthSeriesService.new(stream: @stream).call,
        anomalies: Trust::AnomalyAlertsPresenter.new(channel: @channel, stream: @stream, window: nil).call
      }
    end

    private

    def stream_meta
      {
        id: @stream.id,
        started_at: @stream.started_at.iso8601,
        ended_at: @stream.ended_at&.iso8601,
        is_live: @stream.ended_at.nil?,
        peak_ccv: @stream.current_peak_ccv,
        avg_ccv: @stream.current_avg_ccv,
        game_name: @stream.game_name,
        title: @stream.title
      }
    end

    # This stream's own final/latest TI snapshot (NOT the channel's current state — a past stream
    # keeps its own verdict). Label/color are derived client-side from erv_percent (the extension
    # owns the erv-label i18n); we emit the raw, honest numbers.
    def verdict
      tih = TrustIndexHistory.where(stream_id: @stream.id).order(calculated_at: :desc).first
      return nil unless tih

      {
        ti_score: tih.trust_index_score&.to_f,
        classification: tih.classification,
        erv_percent: tih.erv_percent&.to_f&.clamp(0.0, 100.0),
        erv_count: tih.ccv.to_i.positive? ? (tih.ccv * tih.trust_index_score.to_f / 100.0).round : nil,
        cold_start_status: tih.cold_start_status,
        confidence: tih.confidence&.to_f,
        calculated_at: tih.calculated_at&.iso8601
      }
    end
  end
end
