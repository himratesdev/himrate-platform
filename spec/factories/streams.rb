# frozen_string_literal: true

FactoryBot.define do
  factory :stream do
    channel
    started_at { 3.hours.ago }
    ended_at { 1.hour.ago }

    # PR-A1 (EPIC SCALE ARCHITECTURE Step 2): peak_ccv / avg_ccv / duration_ms columns
    # are dropped from `streams`. Canonical home for these stats is `post_stream_reports`
    # (set by PostStreamWorker for ended streams; derived from CcvSnapshot for live).
    #
    # Tests that need post-stream stats should explicitly:
    #
    #   stream = create(:stream, ended_at: 1.hour.ago)
    #   create(:post_stream_report, stream: stream, ccv_peak: 5000, ccv_avg: 4000,
    #     duration_ms: 7_200_000)
    #
    # Tests that need live-stream stats should seed CcvSnapshots:
    #
    #   stream = create(:stream, ended_at: nil)
    #   create(:ccv_snapshot, stream: stream, ccv_count: 5000, timestamp: 1.minute.ago)
    #
    # NO factory transient for peak_ccv / avg_ccv / duration_ms — the explicit creation
    # pattern matches the production data flow (StreamOfflineWorker → PostStreamWorker → PSR.create)
    # and prevents surprise PSR rows that conflict with subsequent explicit create(:post_stream_report).
  end
end
