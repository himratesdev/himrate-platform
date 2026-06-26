# frozen_string_literal: true

# BUG-SCW-CROSS-CHANNEL (2026-06-02): pre-aggregated (username → distinct_channels_24h) snapshot,
# refreshed every 5 min by CrossChannelIntelligenceWorker (T1-057, was CrossChannelDigestRefreshWorker)
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
  # Hash<String, Integer> ONLY for usernames present in the digest (multi-channel chatters that
  # passed `HAVING c > 1` in the refresh worker). Absent usernames are omitted — callers should
  # use {.fetch_with_baseline} unless they specifically want raw digest contents.
  #
  # Case-sensitive: writer (CrossChannelIntelligenceWorker) sources usernames from CH
  # chat_messages which is already IRC-lowercase, and the digest-path reader (ContextBuilder via
  # Clickhouse::ChatQueries.stream_chatters) reads the same lowercase column — both sides agree.
  def self.bulk_lookup(usernames)
    return {} if usernames.nil? || usernames.empty?

    where(username: usernames).pluck(:username, :distinct_channels_24h).to_h
  end

  # CR-258 M1: legacy `Clickhouse::ChatQueries.cross_channel` returned EVERY chatter in the
  # stream (single-channel ones with value 1 included). The downstream signal
  # `TrustIndex::Signals::CrossChannelPresence` uses `cross_channel_counts.size` as the
  # denominator for both value and confidence — dropping single-channel chatters (the ~80-90%
  # long tail filtered by `HAVING c > 1` for digest table compactness) would silently inflate
  # the signal value 5-10× on Flipper flip.
  #
  # This method preserves the legacy contract: every requested username appears in the result,
  # with the digest value for multi-channel chatters and the implicit 1 for single-channel
  # ones (they posted at minimum in this stream's channel, by definition of being in the
  # `stream_chatters` set passed in).
  def self.fetch_with_baseline(usernames)
    return {} if usernames.nil? || usernames.empty?

    hits = bulk_lookup(usernames)
    usernames.each_with_object(hits) { |u, h| h[u] ||= 1 }
  end
end
