# frozen_string_literal: true

# CR-255 Nit-1: widen `account_age_days_capped` + `total_hours_capped` from `integer`
# to `numeric(8,2)`. PR1 framework migration declared them integer, but `MaturitySignals`
# returns `Float` (`.round(2)`) — PG would silently truncate decimals on persistence,
# masking precision the spec asserts against the in-memory Float.
#
# Both bounded:
# - `account_age_days_capped` ≤ 365.00 (AGE_CAP_DAYS) — numeric(8,2) cap 999_999.99 ≫ bound
# - `total_hours_capped`     ≤ 1000.00 (HOURS_CAP) — same headroom
#
# `total_streams_capped` stays integer — it's a `COUNT` result, naturally integer, no
# precision lost.
#
# Same pattern as PR4 hotfix (20260602010000) — widen once, properly, no follow-up
# truncation surprises. Per [[feedback-no-throwaway-go-to-final-architecture]].
class WidenMaturityCappedColumns < ActiveRecord::Migration[8.0]
  def up
    change_column :stream_feature_vectors, :account_age_days_capped, :decimal, precision: 8, scale: 2
    change_column :stream_feature_vectors, :total_hours_capped, :decimal, precision: 8, scale: 2
  end

  def down
    # Rolling back narrows to integer — Float values would silently truncate. If reverting,
    # truncate or null out fractional values first:
    #   UPDATE stream_feature_vectors
    #     SET account_age_days_capped = floor(account_age_days_capped),
    #         total_hours_capped       = floor(total_hours_capped);
    change_column :stream_feature_vectors, :account_age_days_capped, :integer
    change_column :stream_feature_vectors, :total_hours_capped, :integer
  end
end
