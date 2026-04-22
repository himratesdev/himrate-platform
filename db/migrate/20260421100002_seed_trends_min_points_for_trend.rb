# frozen_string_literal: true

# TASK-039 Phase C1 CR N-1: Seed minimum-points threshold для trend compute
# (previously hardcoded MIN_STREAMS_FOR_TREND=3 в ErvEndpointService/TrustIndexEndpointService).
# Build-for-years: admin-tunable без deploy.

class SeedTrendsMinPointsForTrend < ActiveRecord::Migration[8.0]
  def up
    SignalConfiguration.upsert_all(
      [
        { signal_type: "trends", category: "trend", param_name: "min_points_for_trend", param_value: 3,
          created_at: Time.current, updated_at: Time.current }
      ],
      unique_by: %i[signal_type category param_name],
      on_duplicate: :skip
    )
  end

  def down
    SignalConfiguration.where(signal_type: "trends", category: "trend", param_name: "min_points_for_trend").delete_all
  end
end
