# frozen_string_literal: true

# CR-253 H1: widen `follower_growth_cv_90d` precision before first prod run.
#
# PR1 framework migration declared `numeric(8, 4)` (cap 9999.9999). CV is
# `std / |mean|`; the service guard rejects only exactly-zero mean, so a
# realistic volatile channel can land mean≈1 with std≈1000+ → CV≈1000 ≪ cap,
# but a near-balanced churn series (smallest non-zero |mean| over N=90 deltas
# ≈ 0.011) with σ≈1000 → CV≈90_000 → `PG::NumericValueOutOfRange`.
#
# Same root cause and same fix shape as PR4 hotfix (`20260602010000_widen_*`):
# widen once с large margin per [[feedback-no-throwaway-go-to-final-architecture]].
# Caught at CR time, before the worker hits a dead-job — exactly the pattern
# PR4 didn't catch and which the hotfix had to chase later in prod.
#
# Other three Growth features (`growth_engagement_correlation` ∈ [-1, 1],
# `follow_unfollow_churn_rate` ∈ [0, 1], `attributed_spike_ratio` ∈ [0, 1])
# are bounded и safe at `(8, 4)` — no widening required.
class WidenFollowerGrowthCv90d < ActiveRecord::Migration[8.0]
  def up
    change_column :stream_feature_vectors, :follower_growth_cv_90d, :decimal, precision: 14, scale: 4
  end

  def down
    # Down reverts to PR1 precision. Rows with CV >9999.9999 will fail narrowing —
    # if rolling back, truncate offending rows first:
    #   UPDATE stream_feature_vectors SET follower_growth_cv_90d = NULL
    #     WHERE follower_growth_cv_90d > 9999.9999;
    change_column :stream_feature_vectors, :follower_growth_cv_90d, :decimal, precision: 8, scale: 4
  end
end
