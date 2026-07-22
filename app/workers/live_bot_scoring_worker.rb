# frozen_string_literal: true

# TASK-251.8: periodic bot-scoring of LIVE streams (real-time bot presence in the live Trust Index).
#
# BotScoringWorker (TASK-027) only fired post-stream (StreamOfflineWorker), so while a stream was
# live PerUserBotScore was empty for it → TrustIndex::ContextBuilder#fetch_bot_scores returned [] →
# the bot-dependent live signals stayed neutral until the stream ended. This worker re-enqueues
# BotScoringWorker for each live stream on a cron cadence so PerUserBotScore is populated mid-stream
# and the live TI reflects bots in real time. BotScoringWorker is idempotent (upsert by
# stream_id+username), skips chatless streams, and triggers a final SignalCompute — so re-running it
# mid-stream simply refines scores as more chat accumulates; the post-stream run still writes the
# complete final score.

class LiveBotScoringWorker
  include Sidekiq::Job
  # On the :bot_scoring queue (paired with BotScoringWorker) so cron-driven enqueues don't sit
  # behind the :signals backlog. See sidekiq.yml + bot_scoring_worker.rb for rationale.
  sidekiq_options queue: "bot_scoring", retry: 1

  # Bound per run; cron re-runs. BUG-C PR-C2 (2026-07-22): rotate by least-recently-scored
  # (bot_scored_at ASC NULLS FIRST) instead of oldest-started-first, so at >MAX_STREAMS_PER_RUN
  # concurrent live streams the NEWEST streams (where a streamer starts botting) aren't starved,
  # and a zombie (un-closed ended_at) stream can't permanently top the queue — once scored, its
  # bot_scored_at moves it to the back of the rotation.
  MAX_STREAMS_PER_RUN = 300

  def perform
    return unless Flipper.enabled?(:stream_monitor) && Flipper.enabled?(:bot_scoring)

    # Least-recently-scored first (NULLS FIRST = never-scored young streams get priority). Stamp at
    # enqueue so the next run rotates onward — over ceil(live/MAX) runs every live stream is scored.
    stream_ids = Stream.active.order(Arel.sql("bot_scored_at ASC NULLS FIRST")).limit(MAX_STREAMS_PER_RUN).pluck(:id)
    return if stream_ids.empty?

    Stream.where(id: stream_ids).update_all(bot_scored_at: Time.current)
    # BotScoringWorker skips streams with 0 chatters, so no need to pre-filter on chat here.
    stream_ids.each { |stream_id| BotScoringWorker.perform_async(stream_id) }

    if stream_ids.size == MAX_STREAMS_PER_RUN
      Rails.logger.warn("LiveBotScoringWorker: MAX_STREAMS_PER_RUN=#{MAX_STREAMS_PER_RUN} cap bound — the least-recently-scored #{MAX_STREAMS_PER_RUN} live streams scored this run; the rest rotate in next run")
    end
    Rails.logger.info("LiveBotScoringWorker: enqueued bot-scoring for #{stream_ids.size} live streams (least-recently-scored rotation)")
  end
end
