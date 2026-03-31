# frozen_string_literal: true

require "rails_helper"

RSpec.describe PostStreamWindowService do
  let(:channel) { create(:channel) }

  describe ".open?" do
    context "when no streams" do
      it "returns false" do
        expect(described_class.open?(channel)).to be false
      end
    end

    context "when stream ended less than 18h ago" do
      before { create(:stream, channel: channel, started_at: 20.hours.ago, ended_at: 2.hours.ago) }

      it "returns true" do
        expect(described_class.open?(channel)).to be true
      end
    end

    context "when stream ended more than 18h ago" do
      before { create(:stream, channel: channel, started_at: 30.hours.ago, ended_at: 20.hours.ago) }

      it "returns false" do
        expect(described_class.open?(channel)).to be false
      end
    end

    context "when new stream started after last ended" do
      before do
        create(:stream, channel: channel, started_at: 5.hours.ago, ended_at: 3.hours.ago)
        create(:stream, channel: channel, started_at: 1.hour.ago, ended_at: nil)
      end

      it "returns false (new live closes old window)" do
        expect(described_class.open?(channel)).to be false
      end
    end

    context "when stream ended exactly 18h ago" do
      before { create(:stream, channel: channel, started_at: 20.hours.ago, ended_at: 18.hours.ago) }

      it "returns false (window closed at boundary)" do
        expect(described_class.open?(channel)).to be false
      end
    end
  end

  describe ".expires_at" do
    context "when window is open" do
      let!(:stream) { create(:stream, channel: channel, started_at: 5.hours.ago, ended_at: 2.hours.ago) }

      it "returns ended_at + 18 hours" do
        expect(described_class.expires_at(channel)).to be_within(1.second).of(stream.ended_at + 18.hours)
      end
    end

    context "when window is closed" do
      before { create(:stream, channel: channel, started_at: 30.hours.ago, ended_at: 20.hours.ago) }

      it "returns nil" do
        expect(described_class.expires_at(channel)).to be_nil
      end
    end
  end
end
