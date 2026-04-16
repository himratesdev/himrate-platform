# frozen_string_literal: true

require "rails_helper"

RSpec.describe Hs::TiDropDetector do
  let(:channel) { create(:channel) }
  subject(:detector) { described_class.new }

  def create_ti(score, calculated_at)
    stream = create(:stream, channel: channel, started_at: calculated_at, ended_at: calculated_at + 1.hour)
    create(:trust_index_history,
      channel: channel, stream: stream,
      trust_index_score: score, erv_percent: score, ccv: 1000, confidence: 0.85,
      classification: "needs_review", cold_start_status: "full",
      signal_breakdown: {}, calculated_at: calculated_at)
  end

  describe "#call" do
    it "returns nil without baseline history" do
      create_ti(70, 2.days.ago)
      expect(detector.call(channel)).to be_nil
    end

    it "returns negative delta on drop" do
      create_ti(75, 10.days.ago)
      create_ti(55, 1.hour.ago)
      expect(detector.call(channel)).to eq(-20.0)
    end

    it "returns positive delta on rise" do
      create_ti(50, 10.days.ago)
      create_ti(72, 1.hour.ago)
      expect(detector.call(channel)).to eq(22.0)
    end

    it "returns nil for non-existent channel" do
      nobody = create(:channel)
      expect(detector.call(nobody)).to be_nil
    end
  end

  describe "#ti_drop_window_days" do
    it "defaults to 7 when no config" do
      SignalConfiguration.where(signal_type: "recommendation").delete_all
      expect(detector.ti_drop_window_days).to eq(7)
    end

    it "reads from SignalConfiguration when present" do
      SignalConfiguration.find_or_create_by!(
        signal_type: "recommendation", category: "default", param_name: "ti_drop_window_days"
      ) { |c| c.param_value = 14 }
      expect(detector.ti_drop_window_days).to eq(14)
    end
  end
end
