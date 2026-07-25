# frozen_string_literal: true

# TI v2.1 C_pop (population-anchored F_soft accusation, the silent-always-botter fix). Adds two NULLABLE
# per-cell quantiles to calibration_cell_baselines, harvested by the ρ* miner on the same honest-anchor
# pass as rho_star/rho_lo/rho_hi:
#   rho_p1      — the P1 (extreme-low) tail of the cell's honest chat-share distribution. C_pop accuses a
#                 channel whose rho_obs sits BELOW rho_p1 (below 99% of honest peers) — a tail cut, not the
#                 P10 (rho_lo) where the honest bottom decile legitimately lives. Bounds within-cell honest
#                 FP at ≈1% by the definition of the quantile.
#   ccv_typical — the cell-typical online (median CCV for the V-bucket). C_pop's population_elevated? gate
#                 fires only when a channel's online is INFLATED vs this — the discriminator that separates a
#                 silent botter (online inflated) from an honest low-chat channel (online normal-for-cell).
# Both NULL until the re-seed writes them → C_pop is inert on every cell until then (a second dormancy gate
# beyond the cpop_enabled=0.0 kill-switch). Nullable, no default, no backfill — a pure additive column add.
class AddCpopCellQuantiles < ActiveRecord::Migration[8.0]
  def change
    add_column :calibration_cell_baselines, :rho_p1, :decimal, precision: 8, scale: 5, null: true
    add_column :calibration_cell_baselines, :ccv_typical, :decimal, null: true
  end
end
