# frozen_string_literal: true

# TASK-037 FR-001..005, FR-021, FR-022: Compute Streamer Reputation after stream ends.
# 4 components: Growth Pattern (Pearson), Follower Quality (stub), Engagement Consistency (CV),
# Pattern History (botted stream ratio). Min 7 streams. Creates history record (not find_or_initialize).
# Triggered by PostStreamWorker.

class StreamerReputationRefreshWorker
  include Sidekiq::Job
  sidekiq_options queue: :post_stream, retry: 3

  MIN_STREAMS = 7
  LOOKBACK_STREAMS = 30

  def perform(channel_id)
    channel = Channel.find_by(id: channel_id)
    return unless channel

    completed = channel.streams.where.not(ended_at: nil).order(ended_at: :desc)
    stream_count = completed.count
    return if stream_count < MIN_STREAMS

    recent = completed.limit(LOOKBACK_STREAMS).to_a

    growth = compute_growth_pattern(channel, recent)
    quality = compute_follower_quality
    consistency = compute_engagement_consistency(recent)
    pattern = compute_pattern_history(channel)

    StreamerReputation.create!(
      channel: channel,
      growth_pattern_score: growth,
      follower_quality_score: quality,
      engagement_consistency_score: consistency,
      calculated_at: Time.current
    )

    Rails.logger.info(
      "StreamerReputationRefreshWorker: channel #{channel_id} — " \
      "growth=#{growth&.round(1)} quality=#{quality} consistency=#{consistency&.round(1)} " \
      "pattern=#{pattern&.round(1)} streams=#{stream_count}"
    )
  end

  private

  # FR-002: Pearson(CCV_trend, follower_trend). Score = 100 × max(0, r).
  def compute_growth_pattern(channel, recent_streams)
    return nil if recent_streams.size < MIN_STREAMS

    ccv_trend = recent_streams.reverse.map { |s| s.avg_ccv.to_f }
    follower_trend = load_follower_trend(channel, recent_streams)
    return nil if follower_trend.nil? || follower_trend.size != ccv_trend.size

    r = pearson_correlation(ccv_trend, follower_trend)
    return 50.0 if r.nil? # undefined (stddev=0)

    (100.0 * [ r, 0 ].max).round(2).clamp(0.0, 100.0)
  end

  # FR-003: Stub 50.0 until GQL batch pipeline (TASK-040).
  def compute_follower_quality
    50.0
  end

  # FR-004: CV(chatter_ratio, N_streams). Score = 100 × (1 - CV).
  def compute_engagement_consistency(recent_streams)
    stream_ids = recent_streams.map(&:id)
    ratios = ChattersSnapshot
      .where(stream_id: stream_ids)
      .group(:stream_id)
      .pluck(
        :stream_id,
        Arel.sql("AVG(auth_ratio)")
      )
      .map { |_sid, avg| avg&.to_f }
      .compact

    return nil if ratios.size < MIN_STREAMS

    mean = ratios.sum / ratios.size
    return 0.0 if mean.zero?

    variance = ratios.sum { |r| (r - mean)**2 } / ratios.size
    cv = Math.sqrt(variance) / mean

    (100.0 * (1.0 - cv)).round(2).clamp(0.0, 100.0)
  end

  # FR-021: Pattern History — botted_stream_ratio. Score = 100 × (1 - ratio).
  def compute_pattern_history(channel)
    total = channel.streams.where.not(ended_at: nil).count
    return nil if total < MIN_STREAMS

    botted = TrustIndexHistory
      .where(channel_id: channel.id)
      .where("trust_index_score < 50")
      .select("DISTINCT stream_id")
      .count

    ratio = botted.to_f / total
    (100.0 * (1.0 - ratio)).round(2).clamp(0.0, 100.0)
  end

  def load_follower_trend(channel, recent_streams)
    recent_streams.reverse.map do |stream|
      snapshot = FollowerSnapshot
        .where(channel_id: channel.id)
        .where("timestamp <= ?", stream.ended_at || stream.started_at)
        .order(timestamp: :desc)
        .pick(:followers_count)

      return nil unless snapshot

      snapshot.to_f
    end
  end

  # Pearson correlation coefficient. Returns nil if undefined (zero variance).
  def pearson_correlation(x, y)
    n = x.size
    return nil if n < 2

    mean_x = x.sum / n
    mean_y = y.sum / n

    cov = x.zip(y).sum { |xi, yi| (xi - mean_x) * (yi - mean_y) }
    std_x = Math.sqrt(x.sum { |xi| (xi - mean_x)**2 })
    std_y = Math.sqrt(y.sum { |yi| (yi - mean_y)**2 })

    return nil if std_x.zero? || std_y.zero?

    cov / (std_x * std_y)
  end
end
