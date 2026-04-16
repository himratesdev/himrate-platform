# frozen_string_literal: true

# TASK-038 FR-038: Simplified worker — delegates computation to Hs::Engine.
# Worker responsibility: fetch channel, call Engine, persist, emit events, invalidate cache.
# All formulas, weights, normalization → Engine.

class HealthScoreRefreshWorker
  include Sidekiq::Job
  sidekiq_options queue: :post_stream, retry: 3

  DEDUPE_WINDOW = 60.seconds

  def perform(channel_id)
    channel = Channel.find_by(id: channel_id)
    return unless channel

    # S8: Idempotency — skip if last HS record is very recent (double-trigger).
    last = HealthScore.where(channel_id: channel.id).order(calculated_at: :desc).pick(:calculated_at)
    if last && (Time.current - last) < DEDUPE_WINDOW
      Rails.logger.info("HealthScoreRefreshWorker: skip channel #{channel_id} — last HS #{((Time.current - last).round)}s ago")
      return
    end

    result = Hs::Engine.new.call(channel)
    return unless result[:health_score]

    hs_record = persist(channel, result)

    Hs::TierChangeDetector.new.call(channel: channel, new_hs_record: hs_record)
    Hs::CategoryChangeDetector.new.call(channel: channel, new_hs_record: hs_record)

    invalidate_cache(channel.id, hs_record.category)

    Rails.logger.info(
      "HealthScoreRefreshWorker: channel #{channel_id} — " \
      "HS=#{result[:health_score].round(1)} class=#{result[:classification]} " \
      "confidence=#{result[:confidence_level]} category=#{result[:category]} " \
      "formula=#{result[:applied_formula]} streams=#{result[:stream_count]}"
    )
  end

  private

  # Must match HealthScoresController#cache_key format exactly.
  def invalidate_cache(channel_id, category)
    version = if category
      SignalConfiguration
        .where(signal_type: "health_score", category: category)
        .maximum(:updated_at)&.to_i || 0
    else
      0
    end
    Rails.cache.delete("health_score:cat_v#{version}:#{channel_id}")
  end

  def persist(channel, result)
    components = result[:components] || {}

    HealthScore.create!(
      channel_id: channel.id,
      stream_id: result[:latest_stream]&.id,
      health_score: result[:health_score].clamp(0.0, 100.0).round(2),
      confidence_level: result[:confidence_level],
      hs_classification: result[:classification],
      category: result[:category],
      ti_component: components[:ti],
      engagement_component: components[:engagement],
      stability_component: components[:stability],
      growth_component: components[:growth],
      consistency_component: components[:consistency],
      calculated_at: Time.current
    )
  end
end
