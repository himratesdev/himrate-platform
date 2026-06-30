# frozen_string_literal: true

# T2-020 StreamBreakdown INC-1: per-minute online timeline for the «Разбор эфира» hero.
# Buckets CcvSnapshot to minute granularity → { t, ccv, real, fake, anomaly }. `real` is the
# estimated-real-viewers average for the minute; `fake` = ccv − real (clamped ≥ 0) — the anomalous
# (manufactured) portion. `anomaly` flags minutes that carry a recorded Anomaly. No fabrication:
# minutes without a real-viewer estimate emit real/fake = nil.
module StreamBreakdown
  class TimelineService
    MAX_POINTS = 500

    def initialize(stream:)
      @stream = stream
    end

    def call
      snapshots = CcvSnapshot.where(stream: @stream).order(timestamp: :asc).to_a
      return [] if snapshots.empty?

      anomaly_minutes = anomaly_minute_set
      points = snapshots.group_by { |s| s.timestamp.change(sec: 0) }.map do |minute, bucket|
        build_point(minute, bucket, anomaly_minutes)
      end
      downsample(points)
    end

    private

    def build_point(minute, bucket, anomaly_minutes)
      ccv = (bucket.sum(&:ccv_count).to_f / bucket.size).round
      reals = bucket.filter_map(&:real_viewers_estimate)
      real = reals.any? ? (reals.sum.to_f / reals.size).round : nil
      fake = real && ccv ? [ ccv - real, 0 ].max : nil
      { t: minute.iso8601, ccv: ccv, real: real, fake: fake, anomaly: anomaly_minutes.include?(minute) }
    end

    def anomaly_minute_set
      Anomaly.where(stream: @stream).pluck(:timestamp).map { |ts| ts.change(sec: 0) }.to_set
    end

    # Keep at most MAX_POINTS by even decimation (preserves shape; never invents points).
    def downsample(points)
      return points if points.size <= MAX_POINTS

      step = (points.size.to_f / MAX_POINTS).ceil
      points.each_slice(step).map(&:first)
    end
  end
end
