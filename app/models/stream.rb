# frozen_string_literal: true

class Stream < ApplicationRecord
  belongs_to :channel

  has_many :signals, class_name: "TiSignal", foreign_key: "stream_id", dependent: :destroy
  has_many :ccv_snapshots, dependent: :destroy
  has_many :chatters_snapshots, dependent: :destroy
  # PR 1e-B (TASK-251.14): chat_messages PG table dropped + ChatMessage model deleted.
  # Removed has_many :chat_messages — would NameError on eager_load in production boot.
  has_many :erv_estimates, dependent: :destroy
  has_many :per_user_bot_scores, dependent: :destroy
  has_many :trust_index_histories, dependent: :destroy
  has_many :raid_attributions, dependent: :destroy
  has_many :anomalies, dependent: :destroy
  has_many :predictions_polls, dependent: :destroy
  has_one :post_stream_report, dependent: :destroy
  # 2026-06-01 fix: missing cascades caused FK violation on Stream.destroy (Phase 2 fuse
  # cleanup hit this on cross_channel_presences).
  #
  # CrossChannelPresence: Signal #8 evidence — per-user×channel lifetime record (UNIQUE
  # username + channel_id). `belongs_to :stream, optional: true` deliberately allows the
  # row to outlive any specific Stream — stream_id is metadata pointing at the broadcast
  # where the user was last/first observed. Cascade MUST be :nullify, NOT :destroy:
  # wiping the cross-channel evidence on stream delete destroys the very data Signal #8
  # depends on. Phase 2 fuse-stream cleanup should explicitly null these out via the
  # cleanup tool rather than rely on cascade semantics that would also fire on legitimate
  # Channel.destroy → streams.destroy chains.
  has_many :cross_channel_presences, dependent: :nullify
  # Notification declares no after_destroy/before_destroy callbacks (model is empty
  # other than associations) → bulk SQL DELETE is correct + faster than per-row :destroy.
  # If a future Notification adds audit/websocket callbacks, switch to :destroy.
  has_many :notifications, dependent: :delete_all
  # EPIC ML-FEATURE-EXTRACTOR PR1: per-stream ML feature row (composite PK stream_id+version).
  # FK on_delete: :cascade in the migration handles physical cascade; Rails dependent: :destroy
  # is here for ActiveRecord-managed lifecycle (e.g. tests + Phase C-style cleanup tooling).
  has_many :feature_vectors, class_name: "StreamFeatureVector", dependent: :destroy

  MERGE_STATUSES = %w[separate merged primary secondary].freeze

  validates :started_at, presence: true
  validates :merge_status, inclusion: { in: MERGE_STATUSES }, allow_nil: true

  scope :active, -> { where(ended_at: nil) }
  scope :for_channel, ->(channel_id) { where(channel_id: channel_id) }
end
