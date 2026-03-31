# frozen_string_literal: true

FactoryBot.define do
  factory :post_stream_report do
    stream
    trust_index_final { 72.0 }
    erv_percent_final { 72.0 }
    ccv_peak { 5000 }
    ccv_avg { 4000 }
    duration_ms { 7_200_000 }
    signals_summary { {} }
    anomalies { [] }
    generated_at { Time.current }
  end
end
