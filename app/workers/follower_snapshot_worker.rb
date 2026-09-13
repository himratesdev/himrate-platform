# frozen_string_literal: true

# TASK-251.W2a: snapshot monitored channels' follower count from Helix so Streamer Reputation
# Growth (#12 — Pearson of CCV-trend × follower-trend) and Follower Quality (#13 — follower
# spike detection) have data. Both read FollowerSnapshot, but no production worker ever wrote
# one (only Visual-QA seeders) → they returned nil for every real channel.
#
# Helix GET /channels/followers returns the total count with an app access token (only the
# follower LIST requires moderator:read:followers) — verified live on staging. It's one call
# per broadcaster (no batch), so each run is bounded and channels are refreshed at most once
# per STALE_AFTER via channels.followers_synced_at (cron re-runs to clear the daily backlog).
# Runs on :monitoring (NOT the :signals hot path) so it never competes with signal compute.
class FollowerSnapshotWorker
  include Sidekiq::Job
  sidekiq_options queue: :monitoring, retry: 1

  # Two cadences, because the thing worth catching only happens on air.
  #
  # A purchased fleet is pointed at a channel WHILE IT STREAMS, and each account in the batch we
  # enumerated on 2026-09-13 follows exactly one channel — so an activation lands as a step in the
  # follower count. At the old flat daily cadence that step was invisible: one point per channel per
  # day, and the deltas we measured were 24 hours wide, wider than any burst we care about.
  #
  # Hourly for every monitored channel would be ~2.8k Helix calls an hour to watch mostly-idle
  # accounts. Hourly for the ~300 that are live at any moment puts the resolution exactly where a
  # burst can occur and leaves the rest on the daily trend cadence that Reputation #12/#13 need.
  STALE_AFTER_LIVE = 1.hour
  STALE_AFTER_IDLE = 1.day
  MAX_PER_RUN = 250 # cap Helix usage per run (1 call/channel, no batch); cron re-runs to finish

  def perform
    return unless Flipper.enabled?(:stream_monitor) && Flipper.enabled?(:follower_snapshot)

    channels = channels_to_snapshot
    return if channels.empty?

    snapshotted = channels.count { |channel| snapshot_channel(channel) }
    Rails.logger.info("FollowerSnapshotWorker: snapshotted #{snapshotted}/#{channels.size} channels")
  end

  private

  # Live channels first and on the hourly guard; idle ones fill whatever budget is left. Ordering by
  # staleness within each group keeps the rotation fair, so no channel starves.
  def channels_to_snapshot
    live = due(live_channel_ids, STALE_AFTER_LIVE).limit(MAX_PER_RUN).to_a
    remaining = MAX_PER_RUN - live.size
    return live if remaining <= 0

    live + due(nil, STALE_AFTER_IDLE).where.not(id: live.map(&:id)).limit(remaining).to_a
  end

  def due(ids, stale_after)
    scope = Channel.monitored.active
                   .where("followers_synced_at IS NULL OR followers_synced_at < ?", stale_after.ago)
                   .order(Arel.sql("followers_synced_at ASC NULLS FIRST"))
    ids ? scope.where(id: ids) : scope
  end

  def live_channel_ids
    Stream.where(ended_at: nil).distinct.pluck(:channel_id)
  end

  # nil from Helix = transient failure (timeout/429/5xx) or unresolvable broadcaster_id → skip
  # WITHOUT stamping, so it retries next run (no FollowerSnapshot row, no stale stamp). A real
  # count (including 0) → persist a snapshot + backfill followers_total + stamp followers_synced_at.
  # The followers_synced_at guard makes this idempotent within STALE_AFTER (no duplicate daily rows).
  def snapshot_channel(channel)
    count = helix.get_followers_count(broadcaster_id: channel.twitch_id)
    return false if count.nil?

    now = Time.current
    # Atomic: a snapshot without its followers_synced_at stamp would let the next run create a
    # second row for the same day (defeating the once-per-STALE_AFTER guard), so both writes commit
    # together or neither does.
    ActiveRecord::Base.transaction do
      FollowerSnapshot.create!(channel_id: channel.id, timestamp: now, followers_count: count)
      channel.update!(followers_total: count, followers_synced_at: now)
    end
    true
  rescue ActiveRecord::RecordInvalid => e
    Rails.logger.warn("FollowerSnapshotWorker: #{channel.login} snapshot failed (#{e.message})")
    false
  end

  def helix
    @helix ||= Twitch::HelixClient.new
  end
end
