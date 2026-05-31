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
  sidekiq_options queue: :bot_scoring, retry: 1

  # Bound per run; cron re-runs. Follow-up at scale (thousands of concurrent live streams): a
  # Stream#bot_scored_at column to rotate fairly (least-recently-scored first) + incremental/windowed
  # scoring. That also fixes oldest-first starvation AND a zombie stream (un-closed ended_at) that
  # would otherwise permanently top the queue and re-score static chat.
  MAX_STREAMS_PER_RUN = 300

  def perform
    return unless Flipper.enabled?(:stream_monitor) && Flipper.enabled?(:bot_scoring)

    stream_ids = Stream.active.order(:started_at).limit(MAX_STREAMS_PER_RUN).pluck(:id)
    # BotScoringWorker skips streams with 0 chatters, so no need to pre-filter on chat here.
    stream_ids.each { |stream_id| BotScoringWorker.perform_async(stream_id) }

    # Make the cap binding observable: past MAX_STREAMS_PER_RUN some live streams are skipped this
    # run (oldest-first), which is the trigger to implement Stream#bot_scored_at rotation (follow-up).
    if stream_ids.size == MAX_STREAMS_PER_RUN
      Rails.logger.warn("LiveBotScoringWorker: MAX_STREAMS_PER_RUN=#{MAX_STREAMS_PER_RUN} cap reached — newer live streams skipped this run; add Stream#bot_scored_at rotation (TASK-251.8 follow-up)")
    end
    Rails.logger.info("LiveBotScoringWorker: enqueued bot-scoring for #{stream_ids.size} live streams")
  end
end
