# frozen_string_literal: true

require "rails_helper"

RSpec.describe Trends::Attribution::UnattributedFallback do
  let(:channel) { create(:channel) }
  let(:stream) { create(:stream, channel: channel) }
  let(:anomaly) { create(:anomaly, stream: stream, anomaly_type: "viewbot_spike") }

  describe ".call" do
    it "always matches (catch-all fallback)" do
      result = described_class.call(anomaly)
      expect(result[:source]).to eq("unattributed")
      expect(result[:confidence]).to eq(1.0)
    end

    it "populates raw_source_data с anomaly details" do
      result = described_class.call(anomaly)
      expect(result[:raw_source_data][:anomaly_id]).to eq(anomaly.id)
      expect(result[:raw_source_data][:anomaly_type]).to eq("viewbot_spike")
    end
  end
end
