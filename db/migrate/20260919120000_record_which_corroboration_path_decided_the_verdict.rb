# frozen_string_literal: true

# DETECTION-AUDIT 2026-09-19 (ENGINE-RCA Q2). A YELLOW/RED verdict can be decided by four different
# corroboration paths, but the row recorded only two of them (c_hard / c_self). C_inflation,
# c_hard_abs and C_pop left NO trace, so a row could read "accused with no corroborator" while the
# engine was in fact perfectly canonical — the audit had to re-derive the path from reason codes.
# n_chat_eff (the roster N_frac divides by) was never persisted either, so the single number the
# accusation turns on could not be read back off the verdict it produced.
#
# Observability only — nothing here feeds a decision. Nullable, NO default and NO index:
# trust_index_histories is ~8M rows, so each ADD is a catalog-only change, and a NULL honestly means
# "this row predates the write / the path was never evaluated", never "false".
class RecordWhichCorroborationPathDecidedTheVerdict < ActiveRecord::Migration[8.0]
  TIH = :trust_index_histories

  def up
    add_column TIH, :c_inflation, :boolean, if_not_exists: true # CCV-shape inflation corroborator (L4)
    add_column TIH, :c_hard_abs, :boolean, if_not_exists: true  # integer named-count trigger (L4, YELLOW-only)
    add_column TIH, :c_pop, :boolean, if_not_exists: true       # population-anchored corroborator (engine)
    # Effective chat roster: the N_frac denominator and the size floor the named-count path gates on.
    add_column TIH, :n_chat_eff, :decimal, precision: 10, scale: 2, if_not_exists: true
  end

  def down
    %i[c_inflation c_hard_abs c_pop n_chat_eff].each { |col| remove_column TIH, col, if_exists: true }
  end
end
