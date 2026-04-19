# frozen_string_literal: true

# TASK-039 FR-015: Daily rollup aggregation per channel.
# Source of truth для Trends API. Заполняется TrendsAggregationWorker
# (nightly + post-stream hook). Partition-ready (pg_partman monthly).

class TrendsDailyAggregate < ApplicationRecord
  belongs_to :channel

  validates :date, presence: true
  validates :channel_id, uniqueness: { scope: :date }
  validates :streams_count, numericality: { greater_than_or_equal_to: 0 }
  validates :ti_avg, numericality: { in: 0..100, allow_nil: true }
  validates :erv_avg_percent, numericality: { in: 0..100, allow_nil: true }
  validates :discovery_phase_score, numericality: { in: 0..1, allow_nil: true }
  validates :follower_ccv_coupling_r, numericality: { in: -1..1, allow_nil: true }
  validates :botted_fraction, numericality: { in: 0..1, allow_nil: true }
  validates :schema_version, presence: true

  scope :for_period, ->(channel, from, to) {
    where(channel: channel, date: from..to).order(:date)
  }

  scope :with_tier_changes, -> { where(tier_change_on_day: true) }

  scope :with_discovery, -> { where.not(discovery_phase_score: nil) }
end
