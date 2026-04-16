# frozen_string_literal: true

# TASK-038 FR-038: Simplified worker — delegates computation to Hs::Engine.
# Worker responsibility: fetch channel, call Engine, persist, emit events, invalidate cache.
# All formulas, weights, normalization → Engine.

class HealthScoreRefreshWorker
  include Sidekiq::Job
  sidekiq_options queue: :post_stream, retry: 3

  def perform(channel_id)
    channel = Channel.find_by(id: channel_id)
    return unless channel

    result = Hs::Engine.new.call(channel)
    return unless result[:health_score]

    hs_record = persist(channel, result)

    Hs::TierChangeDetector.new.call(channel: channel, new_hs_record: hs_record)
    Hs::CategoryChangeDetector.new.call(channel: channel, new_hs_record: hs_record)

    Rails.cache.delete("health_score:#{channel_id}")

    Rails.logger.info(
      "HealthScoreRefreshWorker: channel #{channel_id} — " \
      "HS=#{result[:health_score].round(1)} class=#{result[:classification]} " \
      "confidence=#{result[:confidence_level]} category=#{result[:category]} " \
      "formula=#{result[:applied_formula]} streams=#{result[:stream_count]}"
    )
  end

  private

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
