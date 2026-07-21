# frozen_string_literal: true

# TASK-085 FR-015: ERV Divergence Detector — extends signal_compute_worker chain.
# Reads ErvEstimate stream-scoped за 15min window. Triggers anomaly при ratio Δ > 10%.
# Severity computed в presenter (yellow Δ ≥ 10%, red ≥ 20% per BR-011).
#
# Reuses AnomalyAlerter dedup pattern (5min window per stream + anomaly_type) per FR-016.

module TrustIndex
  module Signals
    class ErvDivergenceDetector
      WINDOW = 15.minutes
      DELTA_THRESHOLD_PCT = 10.0
      DEDUP_WINDOW = 5.minutes

      # Check real-viewer-share divergence > 10%. Returns array of created anomaly IDs.
      # PR3b (T1-074, gap D-4): v2 writes NO ErvEstimate — under ti_v2_engine the basis is
      # TIH.authenticity (engine_version='v2'). authenticity = 100·(1−F̂/V) is the exact semantic
      # heir of erv_percent (both = "% of online that is real"), so the ratio thresholds carry over
      # unchanged and the detector stays immune to organic CCV growth (a raw ERV-count basis would
      # false-fire on raids). EC-15 GREY rows (authenticity NULL) excluded. details keys keep their
      # names — values remain "% real viewers", the presenter contract (BR-011 delta_pct) is intact.
      def self.check(stream)
        estimates =
          if v2_engine?
            TrustIndexHistory
              .where(stream_id: stream.id, engine_version: "v2")
              .where("calculated_at > ?", WINDOW.ago)
              .where.not(authenticity: nil)
              .order(:calculated_at)
              .pluck(:authenticity)
          else
            ErvEstimate
              .where(stream: stream)
              .where("timestamp > ?", WINDOW.ago)
              .order(:timestamp)
              .pluck(:erv_percent)
          end

        return [] if estimates.size < 2

        baseline = estimates.first.to_f
        latest = estimates.last.to_f
        return [] if baseline.zero?

        delta_pct = ((latest - baseline) / baseline * 100).abs
        return [] if delta_pct < DELTA_THRESHOLD_PCT

        return [] if recent_anomaly_exists?(stream.id)

        anomaly = Anomaly.create!(
          stream: stream,
          timestamp: Time.current,
          anomaly_type: "erv_divergence",
          confidence: 1.0,
          details: {
            delta_pct: delta_pct.round(2),
            # T1-074 surface-audit dual-emit: under v2 the values ARE authenticity — new keys name
            # the axis honestly; the legacy erv_percent-named keys stay for shipped readers and
            # retire in a follow-up once the extension migrates (additive, EC back-compat).
            axis: v2_engine? ? "authenticity" : "erv_percent",
            from_erv_percent: baseline.round(2),
            to_erv_percent: latest.round(2),
            from_authenticity: (v2_engine? ? baseline.round(2) : nil),
            to_authenticity: (v2_engine? ? latest.round(2) : nil),
            window_minutes: (WINDOW / 60).to_i
          }
        )
        [ anomaly.id ]
      rescue ActiveRecord::RecordInvalid => e
        Rails.logger.warn("ErvDivergenceDetector: creation failed for stream #{stream.id} (#{e.message})")
        []
      end

      def self.recent_anomaly_exists?(stream_id)
        Anomaly.where(stream_id: stream_id, anomaly_type: "erv_divergence")
               .where("timestamp > ?", DEDUP_WINDOW.ago).exists?
      end

      # Flag-store hiccup must not take SCW down → false = v1 branch (ErvEstimate, safe pre-flip).
      def self.v2_engine?
        Flipper.enabled?(:ti_v2_engine)
      rescue StandardError
        false
      end

      private_class_method :recent_anomaly_exists?, :v2_engine?
    end
  end
end
