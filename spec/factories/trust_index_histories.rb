# frozen_string_literal: true

FactoryBot.define do
  factory :trust_index_history do
    channel
    stream { nil }
    trust_index_score { 72.0 }
    confidence { 0.85 }
    classification { "needs_review" }
    cold_start_status { "full" }
    erv_percent { 72.0 }
    ccv { 5000 }
    signal_breakdown { { auth_ratio: { value: 0.15, confidence: 0.9 } } }
    calculated_at { 1.minute.ago }

    # PR3b (T1-074): a v2-engine row — the TI v2 contract fields; retired v1 scalars nil
    # (model validation requires trust_index_score only for engine_version='v1').
    trait :v2 do
      engine_version { "v2" }
      trust_index_score { nil }
      confidence { nil }
      classification { nil }
      cold_start_status { nil }
      erv_percent { nil }
      signal_breakdown { nil }
      erv { 3600 }
      erv_lo { 3400 }
      erv_hi { 3800 }
      authenticity { 72.0 }
      authenticity_lo { 68.0 }
      authenticity_hi { 76.0 }
      f_hat { 1400.0 }
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
    end
  end
end
