# frozen_string_literal: true

# TASK-039 Phase A3b CR N-3: extract hardcoded TI ≥ 50 threshold для "clean stream"
# classification в SignalConfiguration. Used by:
#   - TrustIndex::RehabilitationTracker.count_clean_streams_since (TASK-038)
#   - TrustIndex::BonusAcceleratorCalculator.qualifying_clean_streams (TASK-039)
#
# Build-for-years: admin tunable, single source of truth для clean stream definition
# (raised threshold = stricter rehab criteria, lowered = more lenient).

class SeedCleanStreamTiThreshold < ActiveRecord::Migration[8.0]
  def up
    SignalConfiguration.find_or_create_by!(
      signal_type: "trust_index",
      category: "rehabilitation",
      param_name: "clean_stream_ti_threshold"
    ) { |c| c.param_value = 50 }
  end

  def down
    SignalConfiguration.where(
      signal_type: "trust_index",
      category: "rehabilitation",
      param_name: "clean_stream_ti_threshold"
    ).destroy_all
  end
end
