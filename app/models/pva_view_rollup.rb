# frozen_string_literal: true

# TASK-113 BE-2: daily per-(user, channel, game) viewing rollup. PG-аналог будущего ClickHouse
# AggregatingMergeTree MV (миграция 170002 + CONTEXT — CH-cutover-target). Populated by
# PersonalAnalytics::ViewAggregationWorker (инкрементальный upsert из pva_view_events); читается
# PersonalAnalytics::Aggregates::ViewRollupSource → OverviewService (M1-M5). Не показывается в UI напрямую.
class PvaViewRollup < ApplicationRecord
  belongs_to :user

  validates :user_id, presence: true
  validates :twitch_channel_id, presence: true
  validates :date, presence: true
  validates :total_seconds, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :session_count, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :first_seen_at, presence: true
  validates :last_seen_at, presence: true

  scope :for_user, ->(user) { where(user_id: user.id) }
  scope :in_window, ->(from, to) { where(date: from..to) }
end
