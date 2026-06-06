# frozen_string_literal: true

# TASK-PO-DEBUG-DASHBOARD Hot-Lite v0.1: register :po_debug_dashboard Flipper
# flag as OFF. Controller renders 503 when flag is disabled, so the dashboard
# is a no-op until PO explicitly flips it on (via /admin/flipper).
#
# Reversible via `def down` if the flag should be reset.
class DisablePoDebugDashboardFlipper < ActiveRecord::Migration[8.0]
  def up
    Flipper.disable(:po_debug_dashboard)
  end

  def down
    Flipper.enable(:po_debug_dashboard)
  end
end
