# frozen_string_literal: true

# TASK-086 FR-032 (ADR-086 §4.2): read-only model over the `latest_tih_per_stream`
# materialized view — exactly one row per ended stream holding that stream's FINAL
# Trust Index History. Refreshed asynchronously by Trends::LatestTihRefreshWorker
# (enqueued from PostStreamWorker; the MV's UNIQUE index on stream_id makes
# `REFRESH MATERIALIZED VIEW CONCURRENTLY` legal).
#
# Consumers (BR-002): StreamerReputationRefreshWorker#compute_pattern_history reads
# per-stream FINAL TIH only — it reads it here so it stays correct regardless of
# how much intermediate TIH CleanupWorker has pruned. NEVER writeable (it's a view).
#
# Columns (verify against migration 20260720190000 — TI v2 recreate):
#   stream_id (PK), channel_id, engine_version, trust_index_score, erv_percent (v1 bridge),
#   authenticity, erv, erv_lo, erv_hi, band_row, band_sub, band_color, reason_codes,
#   confirmed_anomaly, cold_start_tier, confidence_marker, ccv, confidence, signal_breakdown,
#   calculated_at, trust_index_history_id.

class LatestTihPerStream < ApplicationRecord
  self.table_name = "latest_tih_per_stream"
  self.primary_key = "stream_id"

  belongs_to :stream
  belongs_to :channel

  scope :for_channel, ->(channel_id) { where(channel_id: channel_id) }
  scope :v2, -> { where(engine_version: "v2") }

  def readonly?
    true
  end
end
