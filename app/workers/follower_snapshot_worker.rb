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

  STALE_AFTER = 1.day  # follower counts move slowly; one daily point is enough for #12/#13 trends
  MAX_PER_RUN = 200    # cap Helix usage per run (1 call/channel, no batch); cron re-runs to finish

  def perform
    return unless Flipper.enabled?(:stream_monitor) && Flipper.enabled?(:follower_snapshot)

    channels = channels_to_snapshot
    return if channels.empty?

    snapshotted = channels.count { |channel| snapshot_channel(channel) }
    Rails.logger.info("FollowerSnapshotWorker: snapshotted #{snapshotted}/#{channels.size} channels")
  end

  private

  def channels_to_snapshot
    Channel.monitored.active
           .where("followers_synced_at IS NULL OR followers_synced_at < ?", STALE_AFTER.ago)
           .order(Arel.sql("followers_synced_at ASC NULLS FIRST"))
           .limit(MAX_PER_RUN)
           .to_a
  end

  # nil from Helix = transient failure (timeout/429/5xx) or unresolvable broadcaster_id → skip
  # WITHOUT stamping, so it retries next run (no FollowerSnapshot row, no stale stamp). A real
  # count (including 0) → persist a snapshot + backfill followers_total + stamp followers_synced_at.
  # The followers_synced_at guard makes this idempotent within STALE_AFTER (no duplicate daily rows).
  def snapshot_channel(channel)
    count = helix.get_followers_count(broadcaster_id: channel.twitch_id)
    return false if count.nil?

    now = Time.current
    FollowerSnapshot.create!(channel_id: channel.id, timestamp: now, followers_count: count)
    channel.update!(followers_total: count, followers_synced_at: now)
    true
  rescue ActiveRecord::RecordInvalid => e
    Rails.logger.warn("FollowerSnapshotWorker: #{channel.login} snapshot failed (#{e.message})")
    false
  end

  def helix
    @helix ||= Twitch::HelixClient.new
  end
end
