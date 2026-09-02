# frozen_string_literal: true

# V1-RETIRE (2026-09-02): every row is a v2-engine row — the old v1-shape default and the
# retired scalar columns are gone. `:v2` stays as a NO-OP alias so the many existing
# `create(:trust_index_history, :v2, ...)` call sites keep working unchanged.
FactoryBot.define do
  factory :trust_index_history do
    channel
    stream { nil }
    engine_version { "v2" }
    ccv { 5000 }
    calculated_at { 1.minute.ago }
    erv { 3600 }
    erv_lo { 3400 }
    erv_hi { 3800 }
    authenticity { 72.0 }
    authenticity_lo { 68.0 }
    authenticity_hi { 76.0 }
    f_hat { 1400.0 }
    f_hat_lo { 1200.0 }
    f_hat_hi { 1600.0 }
    rho_obs { 0.23 }
    f_hard { 120.0 }
    f_hard_lo { 110.0 }
    f_soft { 1400.0 }
    f_soft_lo { 1200.0 }
    f_soft_hi { 1600.0 }
    f_self { 0.0 }
    n_frac { 0.02 }
    q_score { 0.9 }
    band_row { 4 }
    band_color { "green" }
    reason_codes { [] }
    confirmed_anomaly { false }
    cold_start_tier { "full" }
    confidence_marker { "reliable" }
    signal_breakdown { nil }

    trait :v2 do
      # no-op alias (the default IS the v2 shape)
    end
  end
end
