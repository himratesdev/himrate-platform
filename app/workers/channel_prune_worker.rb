# frozen_string_literal: true

# TASK-251.2: prune the monitored set — unmonitor non-pinned channels that are confirmed
# banned/deleted (the discovery garbage accumulated before the TASK-251.13 quality-gate).
#
# A channel qualifies for prune when it is monitored, NOT pinned, has been metadata-synced (so we
# actually asked Helix /users) yet still has a blank display_name — meaning Helix returned nothing
# for it (banned / deleted / renamed). Pinned curated channels (TASK-251.12) are ALWAYS protected.
#
# Prune = set is_monitored=false (reversible, NOT a delete): the row + any history is kept and
# auditable, and if the channel ever returns live it is re-added by the quality-gated discovery.
# Bounded per run (MAX_PER_RUN) + batched update_all so it scales to tens of thousands of channels
# without N+1 or long locks; the cron re-runs to drain a backlog and to catch newly-banned channels
# over time. Gated behind the :channel_prune kill-switch (HOOK flag, OFF by default — enabled only
# after a dry-run review).

class ChannelPruneWorker
  include Sidekiq::Job
  sidekiq_options queue: :monitoring, retry: 1

  MAX_PER_RUN = 1000 # bounded batch; cron re-runs to drain larger backlogs

  def perform
    return unless Flipper.enabled?(:stream_monitor) && Flipper.enabled?(:channel_prune)

    rows = eligible.pluck(:id, :login)
    return if rows.empty?

    pruned = Channel.where(id: rows.map(&:first)).update_all(is_monitored: false, updated_at: Time.current)
    Rails.logger.info("ChannelPruneWorker: unmonitored #{pruned} banned non-pinned channels (sample: #{sample(rows)})")
  end

  # Flag-independent, read-only preview for the dry-run rake task. No mutation.
  def preview
    rows = eligible.pluck(:id, :login)
    Rails.logger.info("ChannelPruneWorker[dry-run]: would unmonitor #{rows.size} banned non-pinned channels (sample: #{sample(rows)})")
    { count: rows.size, sample: sample(rows) }
  end

  private

  # Non-pinned, metadata-synced, blank display_name = Helix returned nothing → banned/deleted.
  # Pinned curated channels are excluded (protected). Bounded for scale.
  def eligible
    Channel.monitored.active
           .where(is_pinned: false)
           .where.not(metadata_synced_at: nil)
           .where(display_name: nil)
           .limit(MAX_PER_RUN)
  end

  def sample(rows)
    rows.first(10).map(&:last).inspect
  end
end
