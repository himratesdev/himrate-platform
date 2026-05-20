# frozen_string_literal: true

# TASK-110 FR-021..023: Cross-device sync event canonical store.
# event_hash = SHA256 idempotency key (per FR-023: same event submitted twice → stored once).
# UNIQUE (user_id, event_hash) DB constraint enforces dedupe; insert_all with on_conflict_do_nothing.
class SyncEvent < ApplicationRecord
  EVENT_TYPES = %w[stream_view watchlist_change login].freeze

  belongs_to :user

  validates :user_id, presence: true
  validates :event_type, presence: true, inclusion: { in: EVENT_TYPES }
  validates :event_hash, presence: true, length: { is: 64 }, uniqueness: { scope: :user_id }
  validates :synced_at, presence: true

  scope :recent, ->(limit = 100) { order(synced_at: :desc).limit(limit) }
  scope :for_user, ->(user) { where(user_id: user.id) }

  def self.compute_hash(user_id:, event_type:, payload:, synced_at:)
    bucket = synced_at.utc.change(sec: 0).iso8601
    # S-1 (CR): recursive key-sort canonical JSON — Hash insertion order не должен влиять на hash,
    # иначе two devices с different key order → different hash → FR-023 idempotency BROKEN.
    canonical = "#{user_id}|#{event_type}|#{canonical_json(payload)}|#{bucket}"
    Digest::SHA256.hexdigest(canonical)
  end

  # Deterministic JSON: sorts Hash keys recursively (insertion-order-independent).
  def self.canonical_json(obj)
    case obj
    when Hash
      obj.transform_keys(&:to_s).sort.to_h.transform_values { |v| deep_sort(v) }.to_json
    when Array
      obj.map { |v| deep_sort(v) }.to_json
    else
      obj.to_json
    end
  end

  def self.deep_sort(obj)
    case obj
    when Hash then obj.transform_keys(&:to_s).sort.to_h.transform_values { |v| deep_sort(v) }
    when Array then obj.map { |v| deep_sort(v) }
    else obj
    end
  end
end
