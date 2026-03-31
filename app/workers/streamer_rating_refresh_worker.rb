# frozen_string_literal: true

# TASK-033 FR-012: Refresh Streamer Rating after stream ends.
# Weighted TI average with exponential decay (recent streams weighted more).
# Triggered by PostStreamWorker.

class StreamerRatingRefreshWorker
  include Sidekiq::Job
  sidekiq_options queue: :post_stream, retry: 3

  RATING_PERIOD = 90.days
  DEFAULT_DECAY_LAMBDA = 0.05

  def perform(channel_id)
    channel = Channel.find_by(id: channel_id)
    unless channel
      Rails.logger.warn("StreamerRatingRefreshWorker: channel #{channel_id} not found")
      return
    end

    ti_data = load_ti_data(channel)
    return if ti_data.empty?

    rating = find_or_initialize_rating(channel)
    decay_lambda = rating.decay_lambda || DEFAULT_DECAY_LAMBDA

    rating_score = compute_weighted_rating(ti_data, decay_lambda)

    rating.update!(
      rating_score: rating_score.clamp(0.0, 100.0).round(2),
      streams_count: ti_data.size,
      calculated_at: Time.current
    )

    Rails.logger.info(
      "StreamerRatingRefreshWorker: channel #{channel_id} — " \
      "rating=#{rating_score.round(1)} streams=#{ti_data.size} decay=#{decay_lambda}"
    )
  end

  private

  # Load final TI per completed stream (last 90 days), newest first
  def load_ti_data(channel)
    cutoff = RATING_PERIOD.ago

    # Get completed stream IDs in the period
    stream_ids = channel.streams
                        .where.not(ended_at: nil)
                        .where("ended_at > ?", cutoff)
                        .order(ended_at: :desc)
                        .pluck(:id)

    return [] if stream_ids.empty?

    # For each stream, get the latest TI score
    stream_ids.filter_map do |stream_id|
      ti_score = TrustIndexHistory.where(stream_id: stream_id)
                                  .order(calculated_at: :desc)
                                  .pick(:trust_index_score)
      ti_score&.to_f
    end
  end

  # Weighted average with exponential decay: weight = exp(-lambda * index)
  # Index 0 = most recent stream, higher index = older streams
  def compute_weighted_rating(ti_scores, decay_lambda)
    total_weight = 0.0
    total_value = 0.0

    ti_scores.each_with_index do |ti, index|
      weight = Math.exp(-decay_lambda * index)
      total_weight += weight
      total_value += ti * weight
    end

    return 0.0 if total_weight.zero?

    total_value / total_weight
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
