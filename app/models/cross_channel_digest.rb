# frozen_string_literal: true

# BUG-SCW-CROSS-CHANNEL (2026-06-02): pre-aggregated (username → distinct_channels_24h) snapshot,
# refreshed every 5 min by CrossChannelDigestRefreshWorker via a single CH scan. Replaces the
# per-stream 24h CH scan that ContextBuilder previously executed inside the SignalComputeWorker
# hot path (5-8s, root cause of :signal_compute backlog).
#
# Read path: `CrossChannelDigest.bulk_lookup(usernames)` — single PG SELECT, ~5ms for 500
# usernames. Write path: idempotent bulk upsert from the refresh worker.

class CrossChannelDigest < ApplicationRecord
  self.primary_key = :username

  validates :username, presence: true
  validates :distinct_channels_24h, presence: true, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :refreshed_at, presence: true

  # Look up the cached distinct-channel count for a batch of usernames. Returns
  # Hash<String, Integer> for the matches; absent usernames are omitted (caller treats as 0 / not
  # cached yet, e.g. fresh chatter not seen by the last refresh cycle).
  #
  # Citext primary key makes the lookup case-insensitive, so callers can pass usernames as they
  # came from CH/Apollo without normalizing first.
  def self.bulk_lookup(usernames)
    return {} if usernames.nil? || usernames.empty?

    where(username: usernames).pluck(:username, :distinct_channels_24h).to_h
  end
end
