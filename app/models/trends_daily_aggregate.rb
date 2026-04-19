# frozen_string_literal: true

# TASK-039 FR-015: Daily rollup aggregation per channel.
# Source of truth для Trends API. Заполняется TrendsAggregationWorker
# (nightly + post-stream hook). Partition-ready (pg_partman monthly).

class TrendsDailyAggregate < ApplicationRecord
  # Canonical TI classifications (source: TrustIndexHistory::CLASSIFICATIONS).
  # Duplicate intentional — build-for-years: model self-contained, не depends on load order.
  CLASSIFICATIONS = %w[trusted needs_review suspicious fraudulent].freeze

  # schema_version bumped при breaking change response shape.
  # v2 включает discovery_phase_score / follower_ccv_coupling_r / tier_change_on_day / best/worst.
  SUPPORTED_SCHEMA_VERSIONS = [ 2 ].freeze

  belongs_to :channel

  validates :date, presence: true
  validates :channel_id, uniqueness: { scope: :date }

  # Counts / absolute
  validates :streams_count, numericality: { greater_than_or_equal_to: 0 }
  validates :ccv_avg, numericality: { greater_than_or_equal_to: 0, allow_nil: true }
  validates :ccv_peak, numericality: { greater_than_or_equal_to: 0, allow_nil: true }

  # Trust Index (0..100)
  validates :ti_avg, numericality: { in: 0..100, allow_nil: true }
  validates :ti_std, numericality: { greater_than_or_equal_to: 0, allow_nil: true }
  validates :ti_min, numericality: { in: 0..100, allow_nil: true }
  validates :ti_max, numericality: { in: 0..100, allow_nil: true }

  # ERV percentages (0..100)
  validates :erv_avg_percent, numericality: { in: 0..100, allow_nil: true }
  validates :erv_min_percent, numericality: { in: 0..100, allow_nil: true }
  validates :erv_max_percent, numericality: { in: 0..100, allow_nil: true }

  # Fractions / scores (0..1)
  validates :botted_fraction, numericality: { in: 0..1, allow_nil: true }
  validates :discovery_phase_score, numericality: { in: 0..1, allow_nil: true }
  # Pearson r (-1..1)
  validates :follower_ccv_coupling_r, numericality: { in: -1..1, allow_nil: true }

  # Classification — canonical TI labels only
  validates :classification_at_end, inclusion: { in: CLASSIFICATIONS }, allow_nil: true

  # Cache versioning — enforced inclusion (prevents drift).
  validates :schema_version, presence: true, inclusion: { in: SUPPORTED_SCHEMA_VERSIONS }

  scope :for_period, ->(channel, from, to) {
    where(channel: channel, date: from..to).order(:date)
  }

  scope :with_tier_changes, -> { where(tier_change_on_day: true) }

  scope :with_discovery, -> { where.not(discovery_phase_score: nil) }
end
