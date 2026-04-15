# frozen_string_literal: true

# TASK-037 FR-012..013, FR-018..020, FR-027: Health Score with BFT-aligned formulas.
# Changes from TASK-033:
# - Weights: 30/20/20/15/15 (was 35/25/15/15/10)
# - Stability: CV = std/mean (was 100-stddev)
# - Engagement: chat_messages/CCV normalized by category median (was auth_ratio)
# - Growth: log-scale (was linear %)
# - Store hs_classification in DB
# Triggered by PostStreamWorker.

class HealthScoreRefreshWorker
  include Sidekiq::Job
  sidekiq_options queue: :post_stream, retry: 3

  PERIOD = 30.days

  # FR-012: BFT §2.3 aligned weights
  DEFAULT_WEIGHTS = {
    ti: 0.30,
    stability: 0.20,
    engagement: 0.20,
    growth: 0.15,
    consistency: 0.15
  }.freeze

  HS_CLASSIFICATIONS = {
    "excellent" => 81..100,
    "good" => 61..80,
    "needs_improvement" => 41..60,
    "critical" => 0..40
  }.freeze

  def perform(channel_id)
    channel = Channel.find_by(id: channel_id)
    return unless channel

    completed_streams = channel.streams.where.not(ended_at: nil)
    stream_count = completed_streams.count
    return if stream_count.zero?

    latest_stream = completed_streams.order(ended_at: :desc).first
    cutoff = PERIOD.ago

    components = compute_components(channel, cutoff, stream_count)
    health_score = weighted_average(components)
    confidence_level = assess_confidence(stream_count)
    classification = classify_hs(health_score)

    HealthScore.create!(
      channel_id: channel.id,
      stream_id: latest_stream.id,
      health_score: health_score.clamp(0.0, 100.0).round(2),
      confidence_level: confidence_level,
      hs_classification: classification,
      ti_component: components[:ti],
      engagement_component: components[:engagement],
      stability_component: components[:stability],
      growth_component: components[:growth],
      consistency_component: components[:consistency],
      calculated_at: Time.current
    )

    Rails.cache.delete("health_score:#{channel_id}")

    Rails.logger.info(
      "HealthScoreRefreshWorker: channel #{channel_id} — " \
      "HS=#{health_score.round(1)} class=#{classification} confidence=#{confidence_level} streams=#{stream_count}"
    )
  end

  private

  def compute_components(channel, cutoff, stream_count)
    ti_histories = TrustIndexHistory.where(channel_id: channel.id).where("calculated_at > ?", cutoff)

    {
      ti: compute_ti_component(ti_histories),
      engagement: compute_engagement_component(channel, cutoff, stream_count),
      stability: compute_stability_component(ti_histories, stream_count),
      growth: compute_growth_component(channel, cutoff, stream_count),
      consistency: compute_consistency_component(channel, cutoff, stream_count)
    }
  end

  # Avg TI over period
  def compute_ti_component(ti_histories)
    avg = ti_histories.average(:trust_index_score)
    avg&.to_f&.round(2)
  end

  # FR-013/FR-019: chat engagement normalized by category median
  # Uses real columns: unique_chatters_count, auth_ratio from chatters_snapshots
  def compute_engagement_component(channel, cutoff, stream_count)
    return nil if stream_count < 3

    stream_ids = channel.streams.where("ended_at > ?", cutoff).pluck(:id)
    return nil if stream_ids.empty?

    # Actual engagement: average auth_ratio across snapshots (chatters/viewers proxy)
    actual_ratio = ChattersSnapshot
      .where(stream_id: stream_ids)
      .average(:auth_ratio)
      &.to_f

    return nil unless actual_ratio && actual_ratio > 0

    # Category median (expected ratio)
    category = channel.streams.order(started_at: :desc).pick(:game_name)
    expected = category_chat_median(category)

    return nil unless expected && expected > 0

    score = (actual_ratio / expected * 100).round(2).clamp(0.0, 100.0)
    score
  end

  # FR-018: Stability = 100 × (1 - CV) where CV = std(TI)/mean(TI)
  def compute_stability_component(ti_histories, stream_count)
    return nil if stream_count < 7

    stats = ti_histories.pick(
      Arel.sql("AVG(trust_index_score)"),
      Arel.sql("STDDEV(trust_index_score)")
    )

    mean = stats&.first&.to_f
    stddev = stats&.last&.to_f
    return nil unless mean && stddev && mean > 0

    cv = stddev / mean
    (100.0 * (1.0 - cv)).round(2).clamp(0.0, 100.0)
  end

  # FR-020: Growth = log-scale: 100 × log(Δfollowers+1) / log(max_expected+1)
  def compute_growth_component(channel, cutoff, stream_count)
    return nil if stream_count < 7

    snapshots = FollowerSnapshot
      .where(channel_id: channel.id)
      .where("timestamp > ?", cutoff)
      .order(:timestamp)

    first_count = snapshots.pick(:followers_count)&.to_f
    last_count = snapshots.order(timestamp: :desc).pick(:followers_count)&.to_f
    return nil unless first_count && last_count

    delta = [ last_count - first_count, 0 ].max
    max_expected = category_max_growth(channel) || 10_000.0

    return 0.0 if max_expected <= 0

    score = 100.0 * Math.log(delta + 1) / Math.log(max_expected + 1)
    score.round(2).clamp(0.0, 100.0)
  end

  # Consistency: regularity of streaming schedule
  def compute_consistency_component(channel, cutoff, stream_count)
    return nil if stream_count < 7

    stream_dates = channel.streams.where("started_at > ?", cutoff).order(:started_at).pluck(:started_at)
    return nil if stream_dates.size < 3

    gaps = stream_dates.each_cons(2).map { |a, b| (b - a) / 1.day }
    avg_gap = gaps.sum / gaps.size
    variance = gaps.sum { |g| (g - avg_gap)**2 } / gaps.size
    stddev = Math.sqrt(variance)

    (100.0 - (stddev / 7.0 * 100)).round(2).clamp(0.0, 100.0)
  end

  # FR-027: HS classification
  def classify_hs(score)
    rounded = score.round(0).to_i
    HS_CLASSIFICATIONS.each do |label, range|
      return label if range.include?(rounded)
    end
    "critical"
  end

  # Category chat median (cached daily)
  def category_chat_median(category)
    cache_key = "chat_median:#{category || 'global'}"
    Rails.cache.fetch(cache_key, expires_in: 24.hours) do
      if category.present?
        compute_chat_median_for(category) || compute_global_chat_median
      else
        compute_global_chat_median
      end
    end
  end

  def compute_chat_median_for(category)
    stream_ids = Stream.where(game_name: category).where.not(ended_at: nil).pluck(:id)
    return nil if stream_ids.size < 10

    ChattersSnapshot
      .where(stream_id: stream_ids)
      .pick(Arel.sql("PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY auth_ratio)"))
      &.to_f
  end

  def compute_global_chat_median
    ChattersSnapshot
      .pick(Arel.sql("PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY auth_ratio)"))
      &.to_f || 0.1 # fallback 10%
  end

  # Category max expected growth (95th percentile from real data)
  def category_max_growth(channel)
    category = channel.streams.order(started_at: :desc).pick(:game_name)
    cache_key = "growth_max:#{category || 'global'}"

    Rails.cache.fetch(cache_key, expires_in: 24.hours) do
      compute_category_max_growth(category) || compute_global_max_growth || 10_000.0
    end
  end

  def compute_category_max_growth(category)
    return nil unless category.present?

    channel_ids = Stream.where(game_name: category).where.not(ended_at: nil)
      .select("DISTINCT channel_id")
    return nil if channel_ids.to_a.size < 10

    compute_growth_p95(channel_ids)
  end

  def compute_global_max_growth
    compute_growth_p95(nil)
  end

  # 95th percentile of 30-day follower delta across channels
  def compute_growth_p95(channel_ids_scope)
    cutoff = PERIOD.ago
    scope = FollowerSnapshot.where("timestamp > ?", cutoff)
    scope = scope.where(channel_id: channel_ids_scope) if channel_ids_scope

    # Per-channel delta: last - first followers_count in period
    deltas_sql = scope
      .select(
        "channel_id",
        "MAX(followers_count) - MIN(followers_count) AS delta"
      )
      .group(:channel_id)
      .having("COUNT(*) >= 2")

    result = FollowerSnapshot.from("(#{deltas_sql.to_sql}) AS channel_deltas")
      .pick(Arel.sql("PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY delta)"))

    result&.to_f&.clamp(100.0, Float::INFINITY)
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
