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

  # PR3b v2 contract (T2 api.ts WatchlistChannel) + CR SF-3 follow-up: band_color alone cannot
  # distinguish row 3 «Аудитория реальная» from row 4 «Аномалий не замечено» (both green) —
  # the service emits band_row + the canonical label_key (BandClassifier::LABEL_KEYS_BY_ROW).
  context "under ti_v2_engine" do
    before do
      allow(Flipper).to receive(:enabled?).and_return(false)
      allow(Flipper).to receive(:enabled?).with(:ti_v2_engine).and_return(true)
    end

    it "emits the v2 row contract incl. band_row + canonical label_key" do
      create(:trust_index_history, :v2, channel: channel, band_row: 3, band_color: "green")
      expect(rows.first).to include(
        erv: 3600, band_row: 3, label_key: "band.green_real", band_color: "green",
        authenticity: 72.0
      )
    end

    it "distinguishes row 4 from row 3 despite the same green color" do
      create(:trust_index_history, :v2, channel: channel, band_row: 4, band_color: "green")
      expect(rows.first).to include(band_row: 4, label_key: "band.green_no_anomaly", band_color: "green")
    end

    it "falls back to the grey contract when the channel has no v2 row yet" do
      expect(rows.first).to include(
        erv: nil, band_row: nil, label_key: "band.grey_insufficient", band_color: "grey"
      )
    end

    it "ignores v1 rows entirely (engine-filtered query)" do
      create(:trust_index_history, channel: channel, trust_index_score: 95.0) # v1 default factory
      expect(rows.first).to include(band_row: nil, label_key: "band.grey_insufficient")
    end
  end

  context "with the flag off (v1 branch untouched)" do
    before { allow(Flipper).to receive(:enabled?).and_return(false) }

    it "keeps the v1 contract without v2 keys" do
      create(:trust_index_history, channel: channel, trust_index_score: 95.0, erv_percent: 88.0)
      row = rows.first
      expect(row).to include(ti_score: 95, erv_percent: 88.0, erv_label_color: "green")
      expect(row).not_to have_key(:label_key)
      expect(row).not_to have_key(:band_row)
    end
  end
end
