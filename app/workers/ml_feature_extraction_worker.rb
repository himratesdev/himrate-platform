# frozen_string_literal: true

# EPIC ML-FEATURE-EXTRACTOR PR1: persists StreamFeatureVector row per stream completion.
# Triggered by PostStreamWorker after the final TI/ERV compute committed.
#
# Queue: :post_stream — same as StreamerReputationRefreshWorker (low priority, downstream
# of TI compute, no real-time pressure). Retry 3 matches existing post-stream workers.
#
# Idempotent: find_or_initialize on (stream_id, SCHEMA_VERSION) — re-runs UPDATE the row
# with fresh values, no duplicate inserts. Composite PK enforced by migration.
class MlFeatureExtractionWorker
  include Sidekiq::Job
  sidekiq_options queue: :post_stream, retry: 3

  def perform(stream_id)
    stream = Stream.find_by(id: stream_id)
    unless stream
      Rails.logger.warn("MlFeatureExtractionWorker: stream #{stream_id} not found (may have been deleted) — skipping")
      return
    end

    extractor = Ml::FeatureExtractor.new(stream)
    features = extractor.call
    metadata = extractor.metadata

    record = StreamFeatureVector.find_or_initialize_by(
      stream_id: stream.id,
      version: Ml::FeatureExtractor::SCHEMA_VERSION
    )
    record.assign_attributes(
      calculated_at: Time.current,
      extractor_metadata: metadata,
      **features
    )
    record.save!

    populated = record.populated_feature_count
    Rails.logger.info(
      "MlFeatureExtractionWorker: stream #{stream_id} — " \
      "version=#{record.version} populated=#{populated}/#{StreamFeatureVector::FEATURE_COLUMNS.size}"
    )
  end
end
