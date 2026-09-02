# frozen_string_literal: true

require "rails_helper"

# CR #427 Nit-2: BatchStatsService had zero spec coverage — first specs for the batch
# avg_authenticity aggregation (verified only by live probes until then).
# V1-RETIRE: the v2 branch is unconditional (no ti_v2_engine flag, no v1 avg_erv shape).
RSpec.describe Watchlists::BatchStatsService do
  let(:user) { create(:user) }
  let(:wl_a) { create(:watchlist, user: user) }
  let(:wl_b) { create(:watchlist, user: user) }
  let(:ch1) { create(:channel) }
  let(:ch2) { create(:channel) }

  def stats
    described_class.new(watchlists: [ wl_a, wl_b ], user: user).call
  end

  it "averages authenticity of each watchlist's latest rows" do
    create(:watchlist_channel, watchlist: wl_a, channel: ch1)
    create(:watchlist_channel, watchlist: wl_a, channel: ch2)
    create(:trust_index_history, channel: ch1, authenticity: 90.0)
    create(:trust_index_history, channel: ch2, authenticity: 70.0)

    expect(stats[wl_a.id]).to include(avg_authenticity: 80.0, total: 2)
    expect(stats[wl_a.id]).not_to have_key(:avg_erv)
  end

  it "uses only the LATEST row per channel" do
    create(:watchlist_channel, watchlist: wl_a, channel: ch1)
    create(:trust_index_history, channel: ch1, authenticity: 20.0, calculated_at: 2.hours.ago)
    create(:trust_index_history, channel: ch1, authenticity: 60.0, calculated_at: 1.minute.ago)

    expect(stats[wl_a.id][:avg_authenticity]).to eq(60.0)
  end

  it "returns the nil-average empty contract for a channel-less watchlist" do
    expect(stats[wl_b.id]).to eq(avg_authenticity: nil, live_count: 0, tracked_count: 0, total: 0)
  end
end
