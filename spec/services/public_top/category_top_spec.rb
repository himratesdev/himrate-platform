# frozen_string_literal: true

require "rails_helper"

RSpec.describe PublicTop::CategoryTop do
  def make_channel(login:, ccv:, erv:, game: "Dota 2", band_row: 1, band_color: "green")
    ch = create(:channel, login: login)
    create(:stream, channel: ch, game_name: game, started_at: 1.hour.ago)
    create(:trends_daily_aggregate, channel: ch, date: 2.days.ago.to_date,
                                    ccv_avg: ccv, erv_avg_percent: erv,
                                    categories: { game => 1 },
                                    band_row_at_end: band_row, band_color_at_end: band_color)
    ch
  end

  before { Rails.cache.clear }

  it "returns ranked public-safe rows with the latest band color attached" do
    make_channel(login: "high", ccv: 10_000, erv: 90.0, band_row: 1, band_color: "green")
    make_channel(login: "low", ccv: 2_000, erv: 80.0, band_row: 4, band_color: "yellow")

    rows = described_class.call("Dota 2")

    expect(rows.map { |r| r[:login] }).to eq(%w[high low])
    expect(rows.map { |r| r[:rank] }).to eq([ 1, 2 ])
    first = rows.first
    expect(first[:real_avg_viewers]).to eq(9_000)
    expect(first[:shown_avg_viewers]).to eq(10_000)
    expect(first[:band_label]).to be_present
    expect(first[:band_color]).to eq("green")
    # public-safe: no brand-only fields leak through
    expect(first).not_to have_key(:bot_correction_pct)
    expect(first).not_to have_key(:classification)
  end

  it "scopes rows to the requested category" do
    make_channel(login: "dota", ccv: 5_000, erv: 80.0, game: "Dota 2")
    make_channel(login: "cs", ccv: 6_000, erv: 80.0, game: "CS2")

    expect(described_class.call("Dota 2").map { |r| r[:login] }).to eq(%w[dota])
  end

  it "leaves band fields nil when the channel has no band yet (hide-not-dim)" do
    make_channel(login: "fresh", ccv: 5_000, erv: 80.0, band_row: nil, band_color: nil)

    row = described_class.call("Dota 2").first
    expect(row[:band_color]).to be_nil
  end

  it "caches the computed rows" do
    make_channel(login: "one", ccv: 5_000, erv: 80.0)
    described_class.call("Dota 2")

    expect(Brand::StreamerSearchQuery).not_to receive(:new)
    described_class.call("Dota 2")
  end
end
