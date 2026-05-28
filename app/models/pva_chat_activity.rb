# frozen_string_literal: true

# TASK-113 BE-3 (M6 Communities): daily chat-активность зрителя per канал (client-capture, snapshot-upsert
# via ChatActivityIngestWorker — идемпотентно by replace). Питает M6: activity_level (из message_count) +
# top_emotes (из emote_counts). Читается CommunitiesService (не в UI напрямую). PG-аналог CH
# AggregatingMergeTree — CH-cutover-target (как pva_view_rollups).
class PvaChatActivity < ApplicationRecord
  belongs_to :user

  validates :user_id, presence: true
  validates :twitch_channel_id, presence: true
  validates :date, presence: true
  validates :message_count, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :first_seen_at, presence: true
  validates :last_seen_at, presence: true

  scope :for_user, ->(user) { where(user_id: user.id) }
  scope :in_window, ->(from, to) { where(date: from..to) }
end
