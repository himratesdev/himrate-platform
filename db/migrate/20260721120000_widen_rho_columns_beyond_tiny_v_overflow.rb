# frozen_string_literal: true

# T1-074 post-flip fix: ρ_obs = EIHC / V is unbounded above — a tiny-V live channel (V=1-2 with a
# few dozen chatters) yields ρ ≥ 10, overflowing the M1 numeric(6,5) columns (max 9.99999).
# Under the v2 cutover Persistence writes rho_obs on EVERY compute and SignalComputeWorker has NO
# rescue (fails the stage by design), so affected tiny-V streams never persist a v2 row and the
# job retry-loops on PG::NumericValueOutOfRange (caught by ti-v2-postflip-health, 2026-07-21).
# Widen to numeric(8,5): roster cap 500 / V ≥ 1 bounds ρ_obs at 500 — fits with headroom, keeps
# the raw value truthful for calibration mining (no clamp). Same-scale precision increase is a
# metadata-only ALTER in PG (no table rewrite); latest_tih_per_stream MV does not reference the
# rho columns, so no MV drop/recreate is needed.
class WidenRhoColumnsBeyondTinyVOverflow < ActiveRecord::Migration[8.0]
  def up
    change_column :trust_index_histories, :rho_obs, :decimal, precision: 8, scale: 5
    change_column :trust_index_histories, :rho_self, :decimal, precision: 8, scale: 5
    change_column :trust_index_histories, :rho_self_lo, :decimal, precision: 8, scale: 5
    # same family on the calibration table — per-cell percentiles of the same distribution
    change_column :calibration_cell_baselines, :rho_star, :decimal, precision: 8, scale: 5, null: false
    change_column :calibration_cell_baselines, :rho_lo, :decimal, precision: 8, scale: 5, null: false
    change_column :calibration_cell_baselines, :rho_hi, :decimal, precision: 8, scale: 5, null: false
  end

  def down
    # narrowing back would raise on any persisted ρ ≥ 10 — intentional (data-lossy rollback guard)
    change_column :trust_index_histories, :rho_obs, :decimal, precision: 6, scale: 5
    change_column :trust_index_histories, :rho_self, :decimal, precision: 6, scale: 5
    change_column :trust_index_histories, :rho_self_lo, :decimal, precision: 6, scale: 5
    change_column :calibration_cell_baselines, :rho_star, :decimal, precision: 6, scale: 5, null: false
    change_column :calibration_cell_baselines, :rho_lo, :decimal, precision: 6, scale: 5, null: false
    change_column :calibration_cell_baselines, :rho_hi, :decimal, precision: 6, scale: 5, null: false
  end
end
