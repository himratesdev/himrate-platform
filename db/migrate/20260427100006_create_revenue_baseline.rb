# frozen_string_literal: true

# BUG-010 PR2: revenue baseline (dormant pre-launch). Populated post-launch from financial pipeline.
# CostAttribution::DowntimeCostCalculator queries latest record для cost computation.
# accessory_revenue_weights JSONB per ADR DEC-18 default: db=1.0, redis=0.8, observability=0.0.

class CreateRevenueBaseline < ActiveRecord::Migration[8.0]
  def change
    create_table :revenue_baselines, id: :uuid do |t|
      t.date :period_start, null: false
      t.date :period_end, null: false
      t.decimal :daily_revenue_usd, precision: 20, scale: 2, null: false
      t.jsonb :accessory_revenue_weights, default: {}, null: false
      t.timestamp :calculated_at, null: false
      t.timestamps
    end

    add_index :revenue_baselines, [ :period_start, :period_end ],
              name: "idx_revenue_baseline_period"
  end
end
