# frozen_string_literal: true

require "rails_helper"

RSpec.describe StreamerReputationRefreshWorker, type: :worker do
  it "uses the post_stream queue with retry 3" do
    expect(described_class.get_sidekiq_options["queue"].to_s).to eq("post_stream")
    expect(described_class.get_sidekiq_options["retry"]).to eq(3)
  end

  # TASK-086 FR-032 / BR-002: compute_pattern_history counts ended streams whose
  # FINAL TIH < 50 via the latest_tih_per_stream MV (one row per ended stream),
  # not raw trust_index_histories. So an intermediate dip < 50 on a stream whose
  # final score is ≥ 50 must NOT be counted.
  describe "#compute_pattern_history (private)" do
    let(:channel) { create(:channel) }
    let(:worker) { described_class.new }

    def refresh_mv!
      ActiveRecord::Base.connection.execute("REFRESH MATERIALIZED VIEW latest_tih_per_stream")
    end

    it "counts ended streams whose FINAL TIH < 50 — ignores intermediate dips" do
      # 7 ended streams (MIN_STREAMS). 2 of them end < 50 (botted), 5 end ≥ 50.
      streams = Array.new(7) { create(:stream, channel: channel, started_at: 10.days.ago, ended_at: 9.days.ago) }
      streams.each_with_index do |s, i|
        # intermediate (older) — deliberately a deep dip on stream #0, but it ends ≥ 50
        create(:trust_index_history, channel: channel, stream: s, calculated_at: 9.days.ago - 2.hours, trust_index_score: 5)
        final_score = i < 2 ? 30 : 80
        create(:trust_index_history, channel: channel, stream: s, calculated_at: 9.days.ago - 1.hour, trust_index_score: final_score)
      end
      refresh_mv!

      # 2 of 7 streams have FINAL TIH < 50 → ratio 2/7 → 100 * (1 - 2/7) ≈ 71.43
      expect(worker.send(:compute_pattern_history, channel)).to eq((100.0 * (1.0 - 2.0 / 7)).round(2))
    end

    it "returns nil below MIN_STREAMS ended streams" do
      3.times { create(:stream, channel: channel, started_at: 2.days.ago, ended_at: 1.day.ago) }
      refresh_mv!

      expect(worker.send(:compute_pattern_history, channel)).to be_nil
    end

    it "treats streams not yet in the MV as not-botted (count = 0)" do
      7.times do |i|
        s = create(:stream, channel: channel, started_at: 10.days.ago, ended_at: 9.days.ago)
        create(:trust_index_history, channel: channel, stream: s, calculated_at: 9.days.ago, trust_index_score: i.zero? ? 10 : 80)
      end
      # NOT refreshed → MV empty → 0 botted → perfect score 100.0
      expect(worker.send(:compute_pattern_history, channel)).to eq(100.0)
    end
  end
end
