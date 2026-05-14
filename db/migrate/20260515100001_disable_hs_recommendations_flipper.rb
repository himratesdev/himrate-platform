# frozen_string_literal: true

# TASK-201 Phase 1 (ADR-201, §4.1): Disable :hs_recommendations Flipper flag as
# safety net before HS endpoint removal (Phase 2.4). HS controllers gain
# `prepend_before_action :check_task201_deprecation` wrapper which renders 410
# Gone when the flag is OFF (this state). Reversible via `def down` if
# emergency rollback needed before code removal.
class DisableHsRecommendationsFlipper < ActiveRecord::Migration[8.0]
  def up
    Flipper.disable(:hs_recommendations) if defined?(Flipper)
  end

  def down
    Flipper.enable(:hs_recommendations) if defined?(Flipper)
  end
end
