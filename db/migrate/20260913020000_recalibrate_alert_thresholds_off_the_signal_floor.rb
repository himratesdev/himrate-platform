# frozen_string_literal: true

# Alert thresholds sat at the FLOOR of each signal's observed range, so "anomaly" meant "measured".
#
# Measured 2026-09-13 over three days of production anomalies (92,945 rows, all at confidence
# 0.98–1.00, none with any recorded ccv_impact):
#
#   signal                 observed range        threshold   → fires on
#   ccv_step_function      0.500 … 0.646          0.500        everything (min == threshold)
#   ccv_tier_clustering    0.600 … 1.000          0.600        everything (min == threshold)
#   chatter_ccv_ratio      0.500 … 0.997          0.500        everything above the floor
#   auth_ratio             0.500 … 0.977          0.500        everything above the floor
#
# The consequence was visible to users: 1377 of 1440 GREEN channels carried anomalies, and the
# per-broadcast report on a channel we certify at 99.91% authenticity ("Аудитория реальная") listed
# seventeen of them. A threshold that admits the entire observed range is not a threshold.
#
# New values are the p90 of the values that actually fired. That sample is censored from below —
# sub-threshold measurements were never persisted, since nothing writes the `signals` table — so
# p90-of-fired is a conservative overestimate of the true population p99. Conservative is the right
# direction for an alert, and it is strictly better than a floor that admits 100%.
#
#   ccv_tier_clustering  0.600 → 0.900   (p75 0.795, p90 1.000; 10%+ of fires sit at the maximum)
#   chatter_ccv_ratio    0.500 → 0.900   (p90 0.933 — this signal genuinely spans its range)
#   auth_ratio           0.500 → 0.800   (p90 0.803)
#   ccv_step_function    0.500 → 0.620   (p95 0.619 — see the caveat below)
#
# LEFT ALONE: ccv_chat_correlation (352 fires in three days) and chat_behavior (95) are already
# rare enough to carry information; raising them would only hide what little they say.
#
# CAVEAT ON ccv_step_function: across 22,308 measurements its entire range is 0.500–0.646. A signal
# that never leaves a 0.15-wide band is close to a constant, and no threshold makes a constant
# informative. 0.620 cuts the volume, but the detector itself wants review — recorded here rather
# than silently tuned away.
#
# NEXT CALIBRATION NEEDS THE UNCENSORED DISTRIBUTION. Signal values are computed transiently and
# discarded (no writer for `signals`), so the only visible sample is the one already above
# threshold. Persisting a sampled fraction of full signal vectors would let the next pass set these
# from the real population instead of its tail.
class RecalibrateAlertThresholdsOffTheSignalFloor < ActiveRecord::Migration[8.0]
  THRESHOLDS = {
    "ccv_tier_clustering" => 0.900,
    "chatter_ccv_ratio" => 0.900,
    "auth_ratio" => 0.800,
    "ccv_step_function" => 0.620
  }.freeze

  PREVIOUS = {
    "ccv_tier_clustering" => 0.600,
    "chatter_ccv_ratio" => 0.500,
    "auth_ratio" => 0.500,
    "ccv_step_function" => 0.500
  }.freeze

  def up = apply(THRESHOLDS)
  def down = apply(PREVIOUS)

  private

  def apply(values)
    values.each do |signal_type, value|
      execute(<<~SQL.squish)
        UPDATE signal_configurations
        SET param_value = #{value}, updated_at = NOW()
        WHERE signal_type = '#{signal_type}'
          AND category = 'default'
          AND param_name = 'alert_threshold'
      SQL
    end
  end
end
