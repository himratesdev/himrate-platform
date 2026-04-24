# frozen_string_literal: true

# TASK-039 FR-045 Phase E1: Seed thresholds для `rake trends:detect_timezones`.
# Build-for-years: admin-tunable без deploy.
#
# min_streams_required: minimum streams у канала перед тем как пытаться detection
# (conservative — один-два стрима не дают надёжного signal).
# dominance_threshold: доля streams с dominant language чтобы считать detection valid
# (ниже — многоязычный канал, timezone остаётся UTC).

class SeedTrendsTimezoneDetectionConfig < ActiveRecord::Migration[8.0]
  def up
    now = Time.current
    SignalConfiguration.upsert_all(
      [
        { signal_type: "trends", category: "timezone_detection", param_name: "min_streams_required", param_value: 10,
          created_at: now, updated_at: now },
        { signal_type: "trends", category: "timezone_detection", param_name: "dominance_threshold", param_value: 0.6,
          created_at: now, updated_at: now }
      ],
      unique_by: %i[signal_type category param_name],
      on_duplicate: :skip
    )
  end

  def down
    SignalConfiguration.where(signal_type: "trends", category: "timezone_detection").delete_all
  end
end
