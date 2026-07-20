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

    # CR iter-3 SF-1 (PR-A1 EPIC SCALE ARCHITECTURE): preload :post_stream_report so the
    # downstream `s.current_avg_ccv` derive (compute_growth_pattern line 57) reads the
    # already-loaded association instead of firing one SELECT per stream. Without the
    # preload, this worker would issue up to 30 PSR SELECTs per stream-end run — same N+1
    # pattern that iter-1 fixed in StreamsController/ChannelsController/ChannelBlueprint.
    completed = channel.streams.where.not(ended_at: nil).includes(:post_stream_report).order(ended_at: :desc)
    stream_count = completed.count
    return if stream_count < MIN_STREAMS

    recent = completed.limit(LOOKBACK_STREAMS).to_a

    growth = compute_growth_pattern(channel, recent)
    quality = compute_follower_quality(channel)
    consistency = compute_engagement_consistency(recent)
    pattern = compute_pattern_history(channel)

    StreamerReputation.create!(
      channel: channel,
      growth_pattern_score: growth,
      follower_quality_score: quality,
      engagement_consistency_score: consistency,
      pattern_history_score: pattern,
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
  #
  # PR-A1 (EPIC SCALE ARCHITECTURE Step 2): stream.avg_ccv column dropped — derive via
  # Stream#current_avg_ccv which reads PSR.ccv_avg для ENDED streams. recent_streams is
  # filtered to ended streams upstream (FollowerSnapshot etc rely on ended timing). Any
  # stream без PSR (mid-PostStreamWorker race) returns nil → excluded by `compact`.
  def compute_growth_pattern(channel, recent_streams)
    return nil if recent_streams.size < MIN_STREAMS

    ccv_trend = recent_streams.reverse.map { |s| s.current_avg_ccv&.to_f }.compact
    return nil if ccv_trend.size < MIN_STREAMS

    follower_trend = load_follower_trend(channel, recent_streams)
    return nil if follower_trend.nil? || follower_trend.size != ccv_trend.size

    r = pearson_correlation(ccv_trend, follower_trend)
    return 50.0 if r.nil? # undefined (stddev=0)

    (100.0 * [ r, 0 ].max).round(2).clamp(0.0, 100.0)
  end

  # FR-003: Follower growth organicity — spike detection.
  # Score = 100 × (1 - spike_ratio). Spike = daily growth > 3σ from mean.
  # Will be enriched with per-follower GQL data in TASK-040.
  def compute_follower_quality(channel)
    snapshots = FollowerSnapshot
      .where(channel_id: channel.id)
      .order(:timestamp)
      .pluck(:followers_count)

    return nil if snapshots.size < MIN_STREAMS

    daily_deltas = snapshots.each_cons(2).map { |a, b| (b - a).to_f }
    return 100.0 if daily_deltas.empty? || daily_deltas.all?(&:zero?)

    mean = daily_deltas.sum / daily_deltas.size
    variance = daily_deltas.sum { |d| (d - mean)**2 } / daily_deltas.size
    stddev = Math.sqrt(variance)

    return 100.0 if stddev.zero?

    threshold = mean + 3.0 * stddev
    spikes = daily_deltas.count { |d| d > threshold }
    spike_ratio = spikes.to_f / daily_deltas.size

    (100.0 * (1.0 - spike_ratio)).round(2).clamp(0.0, 100.0)
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
  # TASK-086 FR-032 / BR-002: counts ended streams whose FINAL TIH < 50 via the
  # latest_tih_per_stream materialized view (one row per ended stream). Previously
  # this counted DISTINCT stream_id over raw trust_index_histories — once
  # CleanupWorker pruned intermediate TIH the count could swing (an intermediate
  # dip under 50 would disappear); reading per-stream FINAL TIH makes it stable.
  # Streams with no TIH yet (not in the MV) are correctly not counted.
  def compute_pattern_history(channel)
    total = channel.streams.where.not(ended_at: nil).count
    return nil if total < MIN_STREAMS

    # PR3b (T1-074): dual predicate — the denominator is ALL-TIME ended streams, so the numerator
    # window is inherently mixed-engine for the full TIH retention. A v2-only filter would silently
    # zero pre-cutover botted streams (score inflates to 100 — leniency drift); bare authenticity<50
    # would NULL-skip v1 rows the same way. Requires the MV recreate exposing engine_version +
    # authenticity (same PR).
    botted = LatestTihPerStream
      .where(channel_id: channel.id)
      .where("(engine_version = 'v2' AND authenticity < 50) OR (engine_version = 'v1' AND trust_index_score < 50)")
      .count

    ratio = botted.to_f / total
    (100.0 * (1.0 - ratio)).round(2).clamp(0.0, 100.0)
  end

  def load_follower_trend(channel, recent_streams)
    ordered = recent_streams.reverse
    cutoff_dates = ordered.map { |s| s.ended_at || s.started_at }

    # Single query: latest follower snapshot at or before each stream's end time
    all_snapshots = FollowerSnapshot
      .where(channel_id: channel.id)
      .where("timestamp <= ?", cutoff_dates.max)
      .order(:timestamp)
      .pluck(:timestamp, :followers_count)

    return nil if all_snapshots.empty?

    cutoff_dates.map do |cutoff|
      match = all_snapshots.select { |ts, _| ts <= cutoff }.last
      return nil unless match

      match[1].to_f
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
