# frozen_string_literal: true

# T1-057 MIG-3 (FR-B2): seed the weight_in_ti for the new `temporal_cross_channel` Trust Index
# signal on the EXISTING production DB (db/seeds.rb covers fresh DBs only).
#
# Why this is required for safety, not optional: TrustIndex::Engine#compute_raw_ti reads each
# available signal's weight via SignalConfiguration.value_for and, on ConfigurationMissing, FALLS
# BACK to an EQUAL share (1.0 / available.size). Registering the signal without seeding a weight
# would therefore give it a FULL ~1/12 share the moment it produces a value — a real TI regression.
# Seeding a conservative 0.05 (matches the two lowest existing signals) keeps its contribution
# small; the Flipper :temporal_cross_channel gate (OFF by default) means it has ZERO TI impact until
# deliberately enabled per-env, after which this weight bounds the magnitude. Final calibration is
# TI-territory (ADR DEC-4) — tune this row, no redeploy.
class SeedTemporalCrossChannelSignalConfig < ActiveRecord::Migration[8.1]
  def up
    now = Time.current
    SignalConfiguration.upsert_all(
      [ {
        signal_type: "temporal_cross_channel",
        category: "default",
        param_name: "weight_in_ti",
        param_value: 0.05,
        created_at: now,
        updated_at: now
      } ],
      unique_by: %i[signal_type category param_name],
      on_duplicate: :skip
    )
  end

  def down
    SignalConfiguration.where(signal_type: "temporal_cross_channel").delete_all
  end
end
