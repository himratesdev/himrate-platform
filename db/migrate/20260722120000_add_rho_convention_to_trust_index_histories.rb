# frozen_string_literal: true

# T1-074 TI v2.1 — P0.5 (BUG-A pre-FLIP blocker). Provenance stamp for the ρ_obs convention that
# produced each v2 row's `rho_obs`. Two conventions exist:
#   • "cumulative" — EIHC over the cumulative roster ÷ instant V (today, ti_v2_cowindowed_rho OFF)
#   • "windowed"   — EIHC over the trailing-60min roster ÷ V_W (post-FLIP, flag ON)
# The Rolling-Window self-baseline (ContextBuilder#v2_self_history → ρ_self_lo) and the ρ* miner
# (ti-v2-shadow-mine) BOTH pool ρ_obs across a 90-day horizon; mixing the two conventions corrupts
# the baseline (a windowed ρ_obs compared against a cumulative-derived ρ_self_lo, and vice-versa).
# The stamp lets both consumers segregate by convention so the FLIP re-seed is clean.
#
# ADDITIVE + REVERSIBLE. Nullable, no default: existing v2 rows stay NULL and are read as
# "cumulative" by the consumer (all pre-P0.5 rows predate the flag, so NULL ≡ cumulative). No
# backfill, no table rewrite (nullable string add = metadata-only in PG) → dormant, byte-identical
# behavior while ti_v2_cowindowed_rho stays OFF.
class AddRhoConventionToTrustIndexHistories < ActiveRecord::Migration[8.0]
  def change
    add_column :trust_index_histories, :rho_convention, :string, limit: 12, if_not_exists: true
  end
end
