# frozen_string_literal: true

# BUG-EIHC-500CAP follow-through (CR-564 Must-Fix 1): the scaled-EIHC fix removes the ρ_obs ≤ 500
# bound the numeric(8,5) columns were sized under (20260721120000 widened them EXACTLY to "roster
# cap 500 / V ≥ 1 → ρ ≤ 500 fits with headroom"). Post-fix EIHC ≤ n_roster (uncapped distinct
# chatters — thousands on big channels), so the 2026-07-21 tiny-V incident class returns: one
# glitchy/pre-offline latest-CCV snapshot (v_eff = 1-2) on a channel with ≥1000 windowed chatters
# → ρ_obs ≥ 1000 → PG::NumericValueOutOfRange in Persistence (raw write, no clamp by design) →
# the SCW cutover path has NO rescue → retry-loop → dead jobs / lost verdicts. Widen the family to
# numeric(12,5) (max ~9.99M — n_roster is bounded by real concurrent chatters, well under that):
# keeps the raw value truthful for calibration mining (no clamp, per the 20260721120000 precedent).
# Same-scale precision increase = metadata-only ALTER in PG (no table rewrite); the
# latest_tih_per_stream MV does not reference the rho columns.
class WidenRhoColumnsBeyondUncappedEihc < ActiveRecord::Migration[8.0]
  def up
    change_column :trust_index_histories, :rho_obs, :decimal, precision: 12, scale: 5
    change_column :trust_index_histories, :rho_self, :decimal, precision: 12, scale: 5
    change_column :trust_index_histories, :rho_self_lo, :decimal, precision: 12, scale: 5
    # same family on the calibration table — per-cell percentiles of the same distribution
    change_column :calibration_cell_baselines, :rho_star, :decimal, precision: 12, scale: 5, null: false
    change_column :calibration_cell_baselines, :rho_lo, :decimal, precision: 12, scale: 5, null: false
    change_column :calibration_cell_baselines, :rho_hi, :decimal, precision: 12, scale: 5, null: false
    change_column :calibration_cell_baselines, :rho_p1, :decimal, precision: 12, scale: 5, null: true
  end

  def down
    # narrowing back would raise on any persisted ρ ≥ 1000 — intentional (data-lossy rollback guard)
    change_column :trust_index_histories, :rho_obs, :decimal, precision: 8, scale: 5
    change_column :trust_index_histories, :rho_self, :decimal, precision: 8, scale: 5
    change_column :trust_index_histories, :rho_self_lo, :decimal, precision: 8, scale: 5
    change_column :calibration_cell_baselines, :rho_star, :decimal, precision: 8, scale: 5, null: false
    change_column :calibration_cell_baselines, :rho_lo, :decimal, precision: 8, scale: 5, null: false
    change_column :calibration_cell_baselines, :rho_hi, :decimal, precision: 8, scale: 5, null: false
    change_column :calibration_cell_baselines, :rho_p1, :decimal, precision: 8, scale: 5, null: true
  end
end
