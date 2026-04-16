# frozen_string_literal: true

# TASK-037 FR-008..011, FR-023, FR-026: Streamer Rating with BFT-aligned formulas.
# Changes from TASK-033:
# - Date-based decay (not index-based): weight = exp(-λ × days_since_stream)
# - Bayesian shrinkage for cold start (k=5, per-category prior with global fallback)
# - Confidence level (low/medium/high)
# - Store both rating_observed (pre-shrinkage) and rating_score (post-shrinkage)
# Triggered by PostStreamWorker.

class StreamerRatingRefreshWorker
  include Sidekiq::Job
  sidekiq_options queue: :post_stream, retry: 3

  RATING_PERIOD = 90.days
  DEFAULT_DECAY_LAMBDA = 0.05
  SHRINKAGE_K = 5
  SHRINKAGE_THRESHOLD = 7

  def perform(channel_id)
    channel = Channel.find_by(id: channel_id)
    return unless channel

    ti_data = load_ti_data(channel)
    return if ti_data.empty?

    rating = find_or_initialize_rating(channel)
    decay_lambda = rating.decay_lambda || DEFAULT_DECAY_LAMBDA

    rating_observed = compute_date_weighted_rating(ti_data, decay_lambda)
    streams_count = ti_data.size
    confidence = assess_confidence(streams_count)

    # FR-009/FR-023: Bayesian shrinkage for cold start
    rating_final = if streams_count < SHRINKAGE_THRESHOLD
      apply_bayesian_shrinkage(rating_observed, streams_count, channel)
    else
      rating_observed
    end

    rating.update!(
      rating_score: rating_final.clamp(0.0, 100.0).round(2),
      rating_observed: rating_observed.clamp(0.0, 100.0).round(2),
      streams_count: streams_count,
      confidence_level: confidence,
      calculated_at: Time.current
    )

    Rails.logger.info(
      "StreamerRatingRefreshWorker: channel #{channel_id} — " \
      "observed=#{rating_observed.round(1)} final=#{rating_final.round(1)} " \
      "confidence=#{confidence} streams=#{streams_count} " \
      "bayesian=#{streams_count < SHRINKAGE_THRESHOLD}"
    )
  end

  private

  # Load final TI per completed stream (last 90 days), with ended_at for date-based decay.
  def load_ti_data(channel)
    cutoff = RATING_PERIOD.ago

    streams = channel.streams
      .where.not(ended_at: nil)
      .where("ended_at > ?", cutoff)
      .order(ended_at: :desc)
      .pluck(:id, :ended_at)

    return [] if streams.empty?

    stream_ids = streams.map(&:first)
    ended_at_map = streams.to_h

    ti_by_stream = TrustIndexHistory
      .where(stream_id: stream_ids)
      .select("DISTINCT ON (stream_id) stream_id, trust_index_score")
      .order(:stream_id, calculated_at: :desc)
      .index_by(&:stream_id)

    stream_ids.filter_map do |sid|
      ti = ti_by_stream[sid]&.trust_index_score&.to_f
      next unless ti

      { ti_score: ti, ended_at: ended_at_map[sid] }
    end
  end

  # FR-008: Date-based decay: weight = exp(-λ × days_since_stream)
  def compute_date_weighted_rating(ti_data, decay_lambda)
    now = Time.current
    total_weight = 0.0
    total_value = 0.0

    ti_data.each do |entry|
      days = [ (now - entry[:ended_at]) / 1.day, 0 ].max
      weight = Math.exp(-decay_lambda * days)
      total_weight += weight
      total_value += entry[:ti_score] * weight
    end

    return 0.0 if total_weight.zero?

    total_value / total_weight
  end

  # FR-009/FR-023: Bayesian shrinkage to category prior (or global fallback)
  def apply_bayesian_shrinkage(rating_observed, streams_count, channel)
    prior = category_prior(channel)
    n = streams_count.to_f
    k = SHRINKAGE_K.to_f

    (n / (n + k)) * rating_observed + (k / (n + k)) * prior
  end

  # FR-023: Per-category prior (median TI). Global fallback.
  def category_prior(channel)
    category = channel.streams.order(started_at: :desc).pick(:game_name)

    if category.present?
      cached = Rails.cache.fetch("category_prior:#{category}", expires_in: 24.hours) do
        median_ti_for_category(category)
      end
      return cached if cached
    end

    global_prior
  end

  def median_ti_for_category(category)
    channel_ids = Stream.where(game_name: category)
      .select("DISTINCT channel_id")
    median = TrustIndexHistory
      .where(channel_id: channel_ids)
      .pick(Arel.sql("PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY trust_index_score)"))
    median&.to_f
  end

  def global_prior
    SignalConfiguration.value_for("trust_index", "default", "population_mean").to_f
  rescue SignalConfiguration::ConfigurationMissing
    65.0
  end

  # FR-010: Confidence level
  def assess_confidence(streams_count)
    case streams_count
    when 0..2 then "low"
    when 3..6 then "medium"
    else "high"
    end
  end

  def find_or_initialize_rating(channel)
    StreamerRating.find_or_initialize_by(channel_id: channel.id) do |r|
      r.decay_lambda = DEFAULT_DECAY_LAMBDA
      r.streams_count = 0
      r.calculated_at = Time.current
      r.rating_score = 0
    end
  end
end
