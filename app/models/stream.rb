# frozen_string_literal: true

class Stream < ApplicationRecord
  belongs_to :channel

  has_many :signals, class_name: "TiSignal", foreign_key: "stream_id", dependent: :destroy
  has_many :ccv_snapshots, dependent: :destroy
  has_many :chatters_snapshots, dependent: :destroy
  has_many :chat_messages, dependent: :destroy
  has_many :erv_estimates, dependent: :destroy
  has_many :per_user_bot_scores, dependent: :destroy
  has_many :trust_index_histories, dependent: :destroy
  has_many :raid_attributions, dependent: :destroy
  has_many :anomalies, dependent: :destroy
  has_many :predictions_polls, dependent: :destroy
  has_one :post_stream_report, dependent: :destroy
  # 2026-06-01 fix: cross_channel_presences belongs_to stream (optional FK) but was missing
  # from this cascade list. Stream.destroy raised FK violation in Phase 2 cleanup
  # (delete_fuse_streams_v4) until pre-deleted manually. Adding dependent: :destroy
  # closes the gap — covers Stream.destroy path (notifications also has stream_id FK but
  # uses delete_all-equivalent at app level).
  has_many :cross_channel_presences, dependent: :destroy
  # notifications has stream_id FK but notifications model handles its own lifecycle;
  # observed 0 rows referencing fuse streams in audit — keep delete_all not destroy.
  has_many :notifications, dependent: :delete_all

  MERGE_STATUSES = %w[separate merged primary secondary].freeze

  validates :started_at, presence: true
  validates :merge_status, inclusion: { in: MERGE_STATUSES }, allow_nil: true

  scope :active, -> { where(ended_at: nil) }
  scope :for_channel, ->(channel_id) { where(channel_id: channel_id) }
end
