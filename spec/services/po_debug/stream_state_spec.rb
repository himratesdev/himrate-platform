# frozen_string_literal: true

require "rails_helper"

RSpec.describe PoDebug::StreamState do
  describe ".call" do
    context "PO channel not in DB" do
      before do
        allow(ENV).to receive(:fetch).and_call_original
        allow(ENV).to receive(:fetch).with("PO_TWITCH_LOGIN", "himych").and_return("nonexistent_login")
      end

      it "returns no_channel state" do
        expect(described_class.call).to include(state: "no_channel", po_login: "nonexistent_login")
      end
    end

    context "PO channel exists and offline" do
      let!(:channel) { create(:channel, login: "himych", display_name: "Himych", twitch_id: "9999999") }

      it "returns offline state with last_stream nil if no streams" do
        result = described_class.call
        expect(result).to include(state: "offline")
        expect(result[:last_stream]).to be_nil
      end

      it "returns offline state with last ended stream summary" do
        create(:stream, channel: channel, started_at: 1.hour.ago, ended_at: 30.minutes.ago)
        result = described_class.call
        expect(result[:state]).to eq("offline")
        expect(result[:last_stream]).to include(:id, :started_at, :ended_at)
      end
    end

    context "PO channel live" do
      let!(:channel) { create(:channel, login: "himych", display_name: "Himych", twitch_id: "9999999") }
      let!(:stream) { create(:stream, channel: channel, started_at: 10.minutes.ago, ended_at: nil) }

      it "returns live payload with stream stats" do
        result = described_class.call
        expect(result[:state]).to eq("live")
        expect(result.dig(:channel, :login)).to eq("himych")
        expect(result.dig(:stream, :id)).to eq(stream.id)
        expect(result.dig(:stream, :duration_min)).to be_within(0.5).of(10.0)
      end

      it "does not issue a per-request COUNT(*) on ccv_snapshots (CR M-2)" do
        result = described_class.call
        # Payload contract: no ccv_snapshot_count key (was dropped to avoid
        # SELECT COUNT(*) on a fast-growing table at scale).
        expect(result[:stream]).not_to include(:ccv_snapshot_count)
      end
    end
  end
end
