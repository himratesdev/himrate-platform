# frozen_string_literal: true

require "rails_helper"

# CR #427 Nit-2: BatchStatsService had zero spec coverage — first specs for both engine branches
# (the v2 avg_authenticity branch shipped in PR3b was verified only by live probes until now).
RSpec.describe Watchlists::BatchStatsService do
  let(:user) { create(:user) }
  let(:wl_a) { create(:watchlist, user: user) }
  let(:wl_b) { create(:watchlist, user: user) }
  let(:ch1) { create(:channel) }
  let(:ch2) { create(:channel) }

  def stats
    described_class.new(watchlists: [ wl_a, wl_b ], user: user).call
  end

  context "under ti_v2_engine" do
    before do
      allow(Flipper).to receive(:enabled?).and_return(false)
      allow(Flipper).to receive(:enabled?).with(:ti_v2_engine).and_return(true)
    end

    it "averages authenticity of each watchlist's latest v2 rows (v1 rows ignored)" do
      create(:watchlist_channel, watchlist: wl_a, channel: ch1)
      create(:watchlist_channel, watchlist: wl_a, channel: ch2)
      create(:trust_index_history, :v2, channel: ch1, authenticity: 90.0)
      create(:trust_index_history, :v2, channel: ch2, authenticity: 70.0)
      create(:trust_index_history, channel: ch2, trust_index_score: 10.0) # v1 — must not poison the average

      expect(stats[wl_a.id]).to include(avg_authenticity: 80.0, total: 2)
      expect(stats[wl_a.id]).not_to have_key(:avg_erv)
    end

    it "uses only the LATEST v2 row per channel" do
      create(:watchlist_channel, watchlist: wl_a, channel: ch1)
      create(:trust_index_history, :v2, channel: ch1, authenticity: 20.0, calculated_at: 2.hours.ago)
      create(:trust_index_history, :v2, channel: ch1, authenticity: 60.0, calculated_at: 1.minute.ago)

      expect(stats[wl_a.id][:avg_authenticity]).to eq(60.0)
    end

    it "returns the nil-average empty contract for a channel-less watchlist" do
      expect(stats[wl_b.id]).to eq(avg_authenticity: nil, live_count: 0, tracked_count: 0, total: 0)
    end
  end

  context "with the flag off (v1 branch)" do
    before { allow(Flipper).to receive(:enabled?).and_return(false) }

    it "averages erv_percent and keeps the v1 key shape" do
      create(:watchlist_channel, watchlist: wl_a, channel: ch1)
      create(:trust_index_history, channel: ch1, erv_percent: 88.0)

      expect(stats[wl_a.id]).to include(avg_erv: 88.0, total: 1)
      expect(stats[wl_a.id]).not_to have_key(:avg_authenticity)
    end
  end
end
