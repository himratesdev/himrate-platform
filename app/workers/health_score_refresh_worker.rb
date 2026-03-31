# frozen_string_literal: true

# TASK-033 FR-011: Refresh Health Score after stream ends.
# 5 components: ti, engagement, stability, growth, consistency.
# Confidence level by stream_count. Triggered by PostStreamWorker.

class HealthScoreRefreshWorker
  include Sidekiq::Job
  sidekiq_options queue: :post_stream, retry: 3

  PERIOD = 30.days

  # Default weights, overridable from signal_configurations
  DEFAULT_WEIGHTS = {
    ti: 0.35,
    engagement: 0.25,
    stability: 0.15,
    growth: 0.15,
    consistency: 0.10
  }.freeze

  def perform(channel_id)
    channel = Channel.find_by(id: channel_id)
    unless channel
      Rails.logger.warn("HealthScoreRefreshWorker: channel #{channel_id} not found")
      return
    end

    completed_streams = channel.streams.where.not(ended_at: nil)
    stream_count = completed_streams.count

    return if stream_count.zero?

    latest_stream = completed_streams.order(ended_at: :desc).first
    cutoff = PERIOD.ago

    components = compute_components(channel, cutoff, stream_count)
    health_score = weighted_average(components)
    confidence_level = assess_confidence(stream_count)

    HealthScore.create!(
      channel_id: channel.id,
      stream_id: latest_stream.id,
      health_score: health_score.clamp(0.0, 100.0).round(2),
      confidence_level: confidence_level,
      ti_component: components[:ti],
      engagement_component: components[:engagement],
      stability_component: components[:stability],
      growth_component: components[:growth],
      consistency_component: components[:consistency],
      calculated_at: Time.current
    )

    # Invalidate cache
    Rails.cache.delete("health_score:#{channel_id}")

    Rails.logger.info(
      "HealthScoreRefreshWorker: channel #{channel_id} — " \
      "HS=#{health_score.round(1)} confidence=#{confidence_level} streams=#{stream_count}"
    )
  end

  private

  def compute_components(channel, cutoff, stream_count)
    ti_histories = TrustIndexHistory.where(channel_id: channel.id)
                                    .where("calculated_at > ?", cutoff)

    {
      ti: compute_ti_component(ti_histories),
      engagement: compute_engagement_component(channel, cutoff, stream_count),
      stability: compute_stability_component(ti_histories, stream_count),
      growth: compute_growth_component(channel, cutoff, stream_count),
      consistency: compute_consistency_component(channel, cutoff, stream_count)
    }
  end

  # Avg TI over period (always available if stream_count >= 1)
  def compute_ti_component(ti_histories)
    avg = ti_histories.average(:trust_index_score)
    avg&.to_f&.round(2)
  end

  # Avg auth_ratio from chatters_snapshots (>= 3 streams)
  def compute_engagement_component(channel, cutoff, stream_count)
    return nil if stream_count < 3

    stream_ids = channel.streams.where("ended_at > ?", cutoff).pluck(:id)
    avg_auth = ChattersSnapshot.where(stream_id: stream_ids).average(:auth_ratio)
    return nil unless avg_auth

    (avg_auth.to_f * 100).round(2).clamp(0.0, 100.0)
  end

  # 100 - stddev(TI) over period (>= 7 streams for meaningful stddev)
  def compute_stability_component(ti_histories, stream_count)
    return nil if stream_count < 7

    stddev = ti_histories.pick(Arel.sql("STDDEV(trust_index_score)"))
    return nil unless stddev

    (100.0 - stddev.to_f).round(2).clamp(0.0, 100.0)
  end

  # Follower trend (>= 7 streams)
  def compute_growth_component(channel, cutoff, stream_count)
    return nil if stream_count < 7

    snapshots = FollowerSnapshot.where(channel_id: channel.id)
                                .where("timestamp > ?", cutoff)
                                .order(:timestamp)
                                .pluck(:followers_count)

    return nil if snapshots.size < 2

    first = snapshots.first.to_f
    last = snapshots.last.to_f
    return 50.0 if first.zero?

    growth_pct = ((last - first) / first * 100).clamp(-100, 100)
    # Normalize: -100..+100 → 0..100
    ((growth_pct + 100) / 2).round(2)
  end

  # Stream regularity (>= 7 streams): how consistent is the schedule
  def compute_consistency_component(channel, cutoff, stream_count)
    return nil if stream_count < 7

    stream_dates = channel.streams.where("started_at > ?", cutoff)
                          .order(:started_at)
                          .pluck(:started_at)

    return nil if stream_dates.size < 3

    gaps = stream_dates.each_cons(2).map { |a, b| (b - a) / 1.day }
    avg_gap = gaps.sum / gaps.size
    variance = gaps.sum { |g| (g - avg_gap)**2 } / gaps.size
    stddev = Math.sqrt(variance)

    # Lower stddev = more consistent. Normalize: stddev 0→100, stddev 7+→0
    (100.0 - (stddev / 7.0 * 100)).round(2).clamp(0.0, 100.0)
  end

  def weighted_average(components)
    total_weight = 0.0
    total_value = 0.0

    load_weights.each do |key, weight|
      value = components[key]
      next if value.nil?

      total_weight += weight
      total_value += value * weight
    end

    return 0.0 if total_weight.zero?

    total_value / total_weight
  end

  def load_weights
    db_weights = SignalConfiguration
      .where(signal_type: "health_score", category: "default")
      .where("param_name LIKE 'weight_%'")
      .pluck(:param_name, :param_value)
      .to_h

    DEFAULT_WEIGHTS.each_with_object({}) do |(key, default), weights|
      weights[key] = db_weights["weight_#{key}"]&.to_f || default
    end
  end

  def assess_confidence(stream_count)
    case stream_count
    when 0..2 then "insufficient"
    when 3..6 then "provisional_low"
    when 7..9 then "provisional"
    when 10..29 then "full"
    else "deep"
    end
  end
end
