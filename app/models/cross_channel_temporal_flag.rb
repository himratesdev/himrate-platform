# frozen_string_literal: true

# T1-057 (FR-B): per-user-GLOBAL temporal cross-channel bot flag.
#
# Written by CrossChannelIntelligenceWorker once per cycle from a single ClickHouse scan: a user
# who posts in >=3 DISTINCT channels inside a sliding <=W-second window forms a co-occurrence
# "event"; `event_count` (R) is how many such events recur over the rolling 24h window. The tier
# escalates with R (PO 2026-06-25): R>=2 watch / R>=3 flag / R>=4 yellow / R>=7 confirmed.
#
# Grain note (OQ-3): this is per-user-GLOBAL (cross-stream phenomenon — a user across many channels
# is not owned by any one stream), which is why it is a SEPARATE table and NOT an extension of
# PerUserBotScore (per-stream `belongs_to :stream`). Mirrors CrossChannelDigest: username primary
# key, snapshot-recompute (no accumulator), bulk_lookup read path, pruned by refreshed_at.
class CrossChannelTemporalFlag < ApplicationRecord
  self.primary_key = :username

  # Tiers in ascending severity. `none` is not persisted (only R>=2 rows are written) but is the
  # implicit tier for any username absent from the table.
  TIERS = %w[none watch flag yellow confirmed].freeze
  BOT_TYPES = %w[utility spam unknown].freeze

  validates :username, presence: true
  validates :event_count, presence: true, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :max_concurrent_channels, presence: true, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :bot_flag_tier, presence: true, inclusion: { in: TIERS }
  validates :bot_type, presence: true, inclusion: { in: BOT_TYPES }
  validates :window_seconds, presence: true, numericality: { only_integer: true, greater_than: 0 }
  validates :refreshed_at, presence: true

  # Spam-tier rows are the fraud signal; utility (allowlisted platform bots) are recorded but
  # excluded from the TI fraud value by the TemporalCrossChannel signal.
  scope :spam, -> { where(bot_type: "spam") }

  # Mirror of CrossChannelDigest.bulk_lookup — single PG SELECT for a batch of usernames. Returns
  # Hash<String, {bot_flag_tier:, bot_type:, event_count:, max_concurrent_channels:}> ONLY for
  # usernames present in the table (i.e. R>=2). Absent usernames are omitted (implicit tier "none").
  def self.bulk_lookup(usernames)
    return {} if usernames.nil? || usernames.empty?

    where(username: usernames)
      .pluck(:username, :bot_flag_tier, :bot_type, :event_count, :max_concurrent_channels)
      .to_h do |u, tier, type, r, mc|
        [ u, { bot_flag_tier: tier, bot_type: type, event_count: r, max_concurrent_channels: mc } ]
      end
  end
end
