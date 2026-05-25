# frozen_string_literal: true

# TASK-251.3: keep monitored Channel metadata fresh from Helix /users.
#
# Channels are created by ChannelDiscoveryWorker / StreamOnlineWorker carrying only
# `login` + `is_monitored` → display_name / profile_image_url / broadcaster_type / description
# were null (UI and notifications showed blanks). This worker batch-fetches Helix /users
# (≤100 ids per request) for monitored channels that were never synced or are stale, fills
# the metadata, and stamps metadata_synced_at so each channel is refreshed at most once per
# STALE_AFTER. Bounded per run to cap Helix usage.

class ChannelMetadataRefreshWorker
  include Sidekiq::Job
  sidekiq_options queue: :monitoring, retry: 1

  HELIX_BATCH_SIZE = 100 # Helix /users accepts up to 100 ids per request
  STALE_AFTER = 7.days   # re-sync cadence per channel (names/avatars change rarely)
  MAX_PER_RUN = 1000     # cap Helix usage per run (≤10 calls); cron re-runs to finish backfill

  def perform
    return unless Flipper.enabled?(:stream_monitor)

    channels = channels_to_sync
    return if channels.empty?

    @unsyncable = 0
    synced = channels.each_slice(HELIX_BATCH_SIZE).sum { |batch| sync_slice(batch) }

    # Surface @unsyncable so split amplification is observable: a non-trivial count means many ids
    # are being isolated (each costs extra Helix calls via split) and likely need TASK-251.2 cleanup.
    Rails.logger.info("ChannelMetadataRefreshWorker: synced #{synced}/#{channels.size} channels (#{@unsyncable} unsyncable id(s) isolated)")
  end

  private

  # Fetch + apply metadata for one batch. A single malformed/invalid twitch_id makes Helix reject
  # the WHOLE batch with 400 "Bad Identifiers", so we binary-split on 400 to isolate the offender
  # (stamped processed so it stops poisoning every run) while the valid ids still get synced.
  # Returns the count of channels whose metadata was filled.
  def sync_slice(batch)
    return 0 if batch.empty?

    result = helix.get_users(ids: batch.map(&:twitch_id), raise_on_bad_request: true)
    # nil = transient Helix failure (timeout/429/5xx) → skip without stamping, retry next run.
    # [] = request OK, no such user (banned/deleted) → apply_metadata stamps to avoid retry storm.
    return 0 if result.nil?

    by_id = result.index_by { |u| u["id"] }
    batch.count { |channel| apply_metadata(channel, by_id[channel.twitch_id]) }
  rescue Twitch::HelixClient::BadRequestError => e
    return isolate_bad_id(batch.first, e) if batch.one?

    mid = batch.size / 2
    sync_slice(batch[0...mid]) + sync_slice(batch[mid..])
  end

  # A single id Helix refuses (invalid/malformed — e.g. a leftover test fixture). Stamp it processed
  # so it drops out of channels_to_sync for STALE_AFTER instead of poisoning every run; permanent
  # removal of such rows is TASK-251.2 cleanup. Returns 0 (no metadata was filled).
  #
  # Safe even if a 400 were ever NOT about a specific id: apply_metadata(channel, nil) only stamps
  # metadata_synced_at — it never overwrites an existing display_name/avatar — so the worst case is
  # a one-off re-sync delay of STALE_AFTER, not data loss. (/users by id 400s only on bad ids.)
  def isolate_bad_id(channel, error)
    @unsyncable += 1
    Rails.logger.warn(
      "ChannelMetadataRefreshWorker: unsyncable twitch_id=#{channel.twitch_id} (#{channel.login}) " \
      "— #{error.message.truncate(120)}; marking processed (flag for TASK-251.2 cleanup)"
    )
    apply_metadata(channel, nil)
    0
  end

  def channels_to_sync
    Channel.monitored.active
           .where("metadata_synced_at IS NULL OR metadata_synced_at < ?", STALE_AFTER.ago)
           .order(Arel.sql("metadata_synced_at ASC NULLS FIRST"))
           .limit(MAX_PER_RUN)
           .to_a
  end

  # Stamp metadata_synced_at on every processed channel (even when Helix returns nothing —
  # banned/deleted user) so it isn't retried every run. Returns true when metadata was filled.
  # The Helix-user → Channel mapping lives in Channel#assign_helix_metadata (shared with the
  # curated seeder, TASK-251.12) so the blank-keep semantics have one source of truth.
  def apply_metadata(channel, user)
    if user
      channel.assign_helix_metadata(user)
    else
      channel.metadata_synced_at = Time.current
    end

    channel.save!
    user.present?
  rescue ActiveRecord::RecordInvalid => e
    Rails.logger.warn("ChannelMetadataRefreshWorker: #{channel.login} update failed (#{e.message})")
    false
  end

  def helix
    @helix ||= Twitch::HelixClient.new
  end
end
