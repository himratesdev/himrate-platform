# frozen_string_literal: true

# TASK-038 FR (Architect Q4): TI drop thresholds in SignalConfiguration (tunable post-launch).

class SeedRecommendationConfig < ActiveRecord::Migration[8.0]
  def up
    now = Time.current
    rows = [
      { signal_type: "recommendation", category: "default", param_name: "ti_drop_window_days",
        param_value: 7, created_at: now, updated_at: now },
      { signal_type: "recommendation", category: "default", param_name: "ti_drop_threshold_pts",
        param_value: 15, created_at: now, updated_at: now },
      { signal_type: "recommendation", category: "default", param_name: "rehab_required_clean_streams",
        param_value: 15, created_at: now, updated_at: now },
      { signal_type: "recommendation", category: "default", param_name: "max_recommendations",
        param_value: 5, created_at: now, updated_at: now }
    ]

    SignalConfiguration.upsert_all(rows, unique_by: %i[signal_type category param_name])
  end

  def down
    SignalConfiguration.where(signal_type: "recommendation").delete_all
  end
end
