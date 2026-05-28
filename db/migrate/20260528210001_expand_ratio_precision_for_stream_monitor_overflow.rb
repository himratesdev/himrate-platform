# frozen_string_literal: true

# BUG-251.24: expand `chatters_snapshots.auth_ratio` and `predictions_polls.participation_ratio`
# from numeric(5,4) → numeric(8,4) to stop StreamMonitorWorker silently dropping snapshots when
# the computed ratio ≥ 10.0.
#
# Root cause: `StreamMonitorWorker#save_chatters_snapshot` computes
#   auth_ratio = unique_chatters_60min.to_f / current_ccv
# where the numerator is a 60-minute cumulative count over `chat_messages` and the denominator
# is an instantaneous viewer count. For bursty chat / low momentary CCV the ratio can exceed
# 1.0 (max observed = 9.5 across 486 k existing rows); when the value rounds to ≥ 10.0,
# PG numeric(5,4) overflows and the row insert raises
# `ActiveRecord::RangeError: PG::NumericValueOutOfRange — A field with precision 5, scale 4
# must round to an absolute value less than 10^1`.
#
# 118 DLQ entries accumulated over 2026-05-25 → 2026-05-28 14:05Z (cleanup pending post-deploy).
#
# Why expand rather than clamp in code:
# 1. The Trust Index `auth_ratio` SIGNAL currently abstains server-side
#    (`app/services/trust_index/signals/auth_ratio.rb` → `insufficient(
#    reason: "chatters_present_unavailable_server_side")`), so the raw column is data
#    ingest only — it is NOT a 0–1 probability today.
# 2. Bursty chat-to-viewer ratio (5×+) is itself a signal of inflated CCV / view-only bots —
#    clamping at the ingest layer would discard that information before any downstream
#    consumer sees it.
# 3. Normalization is a SIGNAL concern. When the auth_ratio signal becomes server-side
#    computable (TASK-C1), it will clamp at compute time.
#
# numeric(8,4) max = 9999.9999 — comfortably bounded above any plausible real value.
#
# Storage: PG widens numeric in-place without rewriting rows (variable-precision packed
# representation), so this is metadata-only for the existing 486 k chatters_snapshots and 0
# predictions_polls rows. No table-rewrite cost.
#
# Reversible: `down` shrinks back to numeric(5,4). Guard raises IrreversibleMigration if any
# stored value exceeds 9.9999, refusing silent data-loss — the operator must explicitly cap
# or accept loss before reverting.
class ExpandRatioPrecisionForStreamMonitorOverflow < ActiveRecord::Migration[8.1]
  def up
    change_column :chatters_snapshots, :auth_ratio, :decimal, precision: 8, scale: 4
    change_column :predictions_polls, :participation_ratio, :decimal, precision: 8, scale: 4
  end

  def down
    cs_max = ActiveRecord::Base.connection.select_value("SELECT MAX(auth_ratio) FROM chatters_snapshots")
    pp_max = ActiveRecord::Base.connection.select_value("SELECT MAX(participation_ratio) FROM predictions_polls")
    cs_max = cs_max.to_f if cs_max
    pp_max = pp_max.to_f if pp_max

    if (cs_max && cs_max > 9.9999) || (pp_max && pp_max > 9.9999)
      raise ActiveRecord::IrreversibleMigration,
            "Cannot revert: values > 9.9999 exist (chatters_snapshots.auth_ratio max=#{cs_max.inspect}, " \
            "predictions_polls.participation_ratio max=#{pp_max.inspect}). Operator must explicitly cap " \
            "or accept data-loss before shrinking precision (e.g. " \
            "`UPDATE chatters_snapshots SET auth_ratio = 9.9999 WHERE auth_ratio > 9.9999;`)."
    end

    change_column :chatters_snapshots, :auth_ratio, :decimal, precision: 5, scale: 4
    change_column :predictions_polls, :participation_ratio, :decimal, precision: 5, scale: 4
  end
end
