# frozen_string_literal: true

# EPIC ML-FEATURE-EXTRACTOR PR1: factory для StreamFeatureVector.
# Default: empty-features wireframe state (all-nil per PR1 extractor).
FactoryBot.define do
  factory :stream_feature_vector do
    association :stream
    version { Ml::FeatureExtractor::SCHEMA_VERSION }
    calculated_at { Time.current }
    extractor_metadata { { schema_version: Ml::FeatureExtractor::SCHEMA_VERSION, insufficient_data_reasons: {} } }
  end
end
