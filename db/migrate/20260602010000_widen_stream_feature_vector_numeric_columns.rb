# frozen_string_literal: true

# EPIC ML-FEATURE-EXTRACTOR PR4 hotfix: widen numeric column caps where PR1 schema
# undershot real-world data scale.
#
# Symptom (DV PR #251): MlFeatureExtractionWorker dead jobs с
# `PG::NumericValueOutOfRange: numeric field overflow ... precision 10, scale 3 must
# round to absolute value less than 10^7` on `avg_inter_message_interval_sec`. Real
# persisted MAX = 9_272_712 sec (~107 days), brushing the 10^7 cap. Long-stream tail
# or offline→online cycle mean intervals legitimately exceed the cap.
#
# Fix: widen все potentially-overflow-prone numeric columns from PR1 framework migration
# (20260601200000_create_stream_feature_vectors) с margin для future scale:
# - avg_inter_message_interval_sec: numeric(10,3) → numeric(14,3) (cap 10^11)
# - viewer_retention_avg_sec:       numeric(10,2) → numeric(14,2) (cap 10^12)
# - avg_account_age_days:           numeric(10,2) → numeric(14,2) (cap 10^12 days)
#
# Per [[feedback-no-throwaway-go-to-final-architecture]]: widen to numeric(14,N) once,
# margin для any plausible future input. Companion service-level cap (24h sanity bound)
# in `Ml::Features::ChatSignals` для data anomaly defense.
class WidenStreamFeatureVectorNumericColumns < ActiveRecord::Migration[8.0]
  def up
    change_column :stream_feature_vectors, :avg_inter_message_interval_sec, :decimal, precision: 14, scale: 3
    change_column :stream_feature_vectors, :viewer_retention_avg_sec, :decimal, precision: 14, scale: 2
    change_column :stream_feature_vectors, :avg_account_age_days, :decimal, precision: 14, scale: 2
  end

  def down
    # Down reverts to PR1 precision. Rows с values >10^7 в avg_inter_message_interval_sec
    # will fail the narrowed type — if rolling back, truncate offending rows first.
    change_column :stream_feature_vectors, :avg_inter_message_interval_sec, :decimal, precision: 10, scale: 3
    change_column :stream_feature_vectors, :viewer_retention_avg_sec, :decimal, precision: 10, scale: 2
    change_column :stream_feature_vectors, :avg_account_age_days, :decimal, precision: 10, scale: 2
  end
end
