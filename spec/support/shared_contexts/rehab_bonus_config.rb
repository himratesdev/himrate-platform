# frozen_string_literal: true

# TASK-039 Phase A3b CR N-4: shared SignalConfiguration setup для rehab bonus
# specs. Mirror migrations 20260419100006 (bonus thresholds) +
# 20260420100002 (clean stream TI threshold) — production seeded one-time,
# test env loads structure.sql без data → seed manually.
#
# Usage в spec:
#   include_context "rehab bonus config"
RSpec.shared_context "rehab bonus config" do
  before do
    {
      [ "trust_index", "rehabilitation_bonus", "rehab_bonus_pts_max" ] => 15,
      [ "trust_index", "rehabilitation_bonus", "rehab_bonus_per_qualifying_stream" ] => 1,
      [ "trust_index", "rehabilitation_bonus", "rehab_bonus_percentile_threshold" ] => 80,
      [ "trust_index", "rehabilitation_bonus", "rehab_bonus_acceleration_factor" ] => 0.2,
      [ "trust_index", "rehabilitation", "clean_stream_ti_threshold" ] => 50
    }.each do |(signal_type, category, param), value|
      SignalConfiguration.find_or_create_by!(
        signal_type: signal_type, category: category, param_name: param
      ) { |c| c.param_value = value }
    end
  end
end
