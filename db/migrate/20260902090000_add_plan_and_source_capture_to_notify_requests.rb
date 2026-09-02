# frozen_string_literal: true

# P4 /pricing (2026-09): plan-interest capture while checkout is not wired. The CTA posts
# lk/notify with source="pricing_interest" + the plan id — real demand data, no PSP required.
class AddPlanAndSourceCaptureToNotifyRequests < ActiveRecord::Migration[8.0]
  def change
    add_column :notify_requests, :plan, :string, limit: 32
  end
end
