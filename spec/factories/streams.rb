# frozen_string_literal: true

FactoryBot.define do
  factory :stream do
    channel
    started_at { 3.hours.ago }
    ended_at { 1.hour.ago }

    # PR-A1 (EPIC SCALE ARCHITECTURE Step 2): peak_ccv / avg_ccv / duration_ms columns
    # were dropped from streams. Canonical home for these stats is post_stream_reports
    # (set by PostStreamWorker for ended streams; derived from CcvSnapshot for live).
    #
    # Tests that previously passed these as attributes are wired through transient inputs
    # which auto-build a PostStreamReport association. This is the canonical test ergonomics
    # for ended-stream stats — NOT a back-compat shim; PSR has always owned post-stream
    # aggregates, the dropped columns were a redundant cache.
    transient do
      peak_ccv { nil }
      avg_ccv { nil }
      duration_ms { nil }
    end

    after(:create) do |stream, evaluator|
      next unless [ evaluator.peak_ccv, evaluator.avg_ccv, evaluator.duration_ms ].any?

      psr = PostStreamReport.find_or_initialize_by(stream_id: stream.id)
      psr.ccv_peak = evaluator.peak_ccv if evaluator.peak_ccv
      psr.ccv_avg = evaluator.avg_ccv if evaluator.avg_ccv
      psr.duration_ms = evaluator.duration_ms if evaluator.duration_ms
      psr.generated_at ||= stream.ended_at || Time.current
      psr.save!
    end
  end
end
