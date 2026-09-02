# frozen_string_literal: true

require "rails_helper"

RSpec.describe Watchlists::EnrichmentService do
  let(:user) { create(:user) }
  let(:watchlist) { create(:watchlist, user: user) }
  let(:channel) { create(:channel) }

  before { create(:watchlist_channel, watchlist: watchlist, channel: channel) }

  def rows
    described_class.new(watchlist: watchlist, user: user).call
  end

  # V1-RETIRE: the v2 row contract is unconditional (no ti_v2_engine flag, no v1 branch).
  # CR SF-3 follow-up: band_color alone cannot distinguish row 3 «Аудитория реальная» from
  # row 4 «Аномалий не замечено» (both green) — the service emits band_row + the canonical
  # label_key (BandClassifier::LABEL_KEYS_BY_ROW).
  it "emits the v2 row contract incl. band_row + canonical label_key" do
    create(:trust_index_history, channel: channel, band_row: 3, band_color: "green")
    expect(rows.first).to include(
      erv: 3600, band_row: 3, label_key: "band.green_real", band_color: "green",
      authenticity: 72.0
    )
  end

  it "distinguishes row 4 from row 3 despite the same green color" do
    create(:trust_index_history, channel: channel, band_row: 4, band_color: "green")
    expect(rows.first).to include(band_row: 4, label_key: "band.green_no_anomaly", band_color: "green")
  end

  it "falls back to the grey contract when the channel has no row yet" do
    expect(rows.first).to include(
      erv: nil, band_row: nil, label_key: "band.grey_insufficient", band_color: "grey"
    )
  end
end
