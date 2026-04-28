# frozen_string_literal: true

# BUG-010 PR3 CR M-3: stddev_interval_seconds was computed by trainer но не consumed
# inference. Adding ±1σ bound columns к persist confidence interval per prediction.
class AddIntervalBoundsToDriftForecastPredictions < ActiveRecord::Migration[8.1]
  def change
    add_column :drift_forecast_predictions, :predicted_at_lower_bound, :datetime
    add_column :drift_forecast_predictions, :predicted_at_upper_bound, :datetime
  end
end
