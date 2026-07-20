# frozen_string_literal: true

require "rails_helper"

RSpec.describe Discover::LiveNowQuery do
  let(:user) { create(:user) }

  def live_stream(channel)
    create(:stream, channel: channel, started_at: 1.hour.ago, ended_at: nil)
  end

  describe "#call — TI-v2 engine-aware audience" do
    it "reads the NATIVE v2 count/authenticity/band off a v2 latest row (regression: no null audience post-cutover)" do
      channel = create(:channel, login: "v2chan", display_name: "V2 Chan", is_monitored: true)
      live_stream(channel)
      create(:trust_index_history, :v2, channel: channel, stream: nil,
                                         ccv: 5000, erv: 3600, authenticity: 72.0,
                                         band_row: 3, band_color: "green", calculated_at: 1.minute.ago)

      row = described_class.new(user: user).call.find { |r| r[:login] == "v2chan" }

      expect(row).to be_present
      expect(row[:shown_viewers]).to eq(5000)      # V (engine input)
      expect(row[:real_viewers]).to eq(3600)        # NATIVE erv, not ccv × pct
      expect(row[:erv_percent]).to eq(72.0)         # authenticity
      expect(row[:erv_label]).to eq("Аудитория реальная") # band_row 3 → band.green_real (ru)
      expect(row[:erv_label_color]).to eq("green")
    end

    it "still serves a v1 legacy row within the transition window (ccv × erv%)" do
      channel = create(:channel, login: "v1chan", display_name: "V1 Chan", is_monitored: true)
      live_stream(channel)
      create(:trust_index_history, channel: channel, stream: nil,
                                    engine_version: "v1", ccv: 1000, erv_percent: 80.0,
                                    trust_index_score: 85.0, calculated_at: 1.minute.ago)

      row = described_class.new(user: user).call.find { |r| r[:login] == "v1chan" }

      expect(row).to be_present
      expect(row[:shown_viewers]).to eq(1000)
      expect(row[:real_viewers]).to eq(800)         # 1000 × 80 / 100
      expect(row[:erv_percent]).to eq(80.0)
      expect(row[:ti_score]).to eq(85.0)
      expect(row[:erv_label]).to be_present
    end

    it "ranks channels by real audience across mixed engine versions" do
      big = create(:channel, login: "big", is_monitored: true)
      small = create(:channel, login: "small", is_monitored: true)
      live_stream(big)
      live_stream(small)
      create(:trust_index_history, :v2, channel: big, stream: nil, ccv: 9000, erv: 8000, calculated_at: 1.minute.ago)
      create(:trust_index_history, channel: small, stream: nil, engine_version: "v1",
                                    ccv: 1000, erv_percent: 50.0, calculated_at: 1.minute.ago)

      logins = described_class.new(user: user).call.map { |r| r[:login] }
      expect(logins.index("big")).to be < logins.index("small") # 8000 real > 500 real
    end

    it "ignores a v2 row with no usable audience (erv NULL) and channels with only ghost rows" do
      channel = create(:channel, login: "ghost", is_monitored: true)
      live_stream(channel)
      create(:trust_index_history, :v2, channel: channel, stream: nil, erv: nil, authenticity: nil,
                                         calculated_at: 1.minute.ago)

      row = described_class.new(user: user).call.find { |r| r[:login] == "ghost" }
      # the latest usable-row filter finds none → LEFT JOIN yields NULL audience, sorted last but present
      expect(row&.dig(:real_viewers)).to be_nil if row
    end
  end
end
