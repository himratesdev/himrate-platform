# frozen_string_literal: true

require "rails_helper"

RSpec.describe TrustIndex::Signals::ErvDivergenceDetector do
  let(:channel) { Channel.create!(twitch_id: "ed_ch", login: "ed_channel", display_name: "ED") }
  let(:stream) { Stream.create!(channel: channel, started_at: 1.hour.ago) }

  def make_estimate(percent:, timestamp:)
    ErvEstimate.create!(
      stream: stream, timestamp: timestamp,
      erv_count: (percent * 10).to_i, erv_percent: percent, confidence: 1.0
    )
  end

  describe ".check" do
    it "creates erv_divergence anomaly when |delta| > 10% в 15min window" do
      make_estimate(percent: 80, timestamp: 12.minutes.ago)
      make_estimate(percent: 60, timestamp: 1.minute.ago)

      expect { described_class.check(stream) }.to change(Anomaly, :count).by(1)

      anomaly = Anomaly.last
      expect(anomaly.anomaly_type).to eq("erv_divergence")
      expect(anomaly.details["delta_pct"]).to be_within(0.1).of(25.0)  # |60-80|/80 = 25%
      expect(anomaly.details["from_erv_percent"]).to be_within(0.1).of(80.0)
      expect(anomaly.details["to_erv_percent"]).to be_within(0.1).of(60.0)
      expect(anomaly.details["window_minutes"]).to eq(15)
    end

    it "creates anomaly также для positive divergence (ERV jumped up)" do
      make_estimate(percent: 50, timestamp: 12.minutes.ago)
      make_estimate(percent: 70, timestamp: 1.minute.ago)

      expect { described_class.check(stream) }.to change(Anomaly, :count).by(1)
      expect(Anomaly.last.details["delta_pct"]).to be_within(0.1).of(40.0)  # |70-50|/50 = 40%
    end

    it "does NOT create anomaly when |delta| <= 10%" do
      make_estimate(percent: 80, timestamp: 12.minutes.ago)
      make_estimate(percent: 75, timestamp: 1.minute.ago)  # 6.25% delta

      expect { described_class.check(stream) }.not_to change(Anomaly, :count)
    end

    it "no-op when estimates.size < 2 (insufficient data — EC-22)" do
      make_estimate(percent: 80, timestamp: 1.minute.ago)
      expect { described_class.check(stream) }.not_to change(Anomaly, :count)
    end

    it "no-op when baseline = 0 (avoid division by zero)" do
      make_estimate(percent: 0, timestamp: 12.minutes.ago)
      make_estimate(percent: 50, timestamp: 1.minute.ago)

      expect { described_class.check(stream) }.not_to change(Anomaly, :count)
    end

    it "deduplicates within 5min window (FR-016 AnomalyAlerter pattern)" do
      make_estimate(percent: 80, timestamp: 12.minutes.ago)
      make_estimate(percent: 60, timestamp: 1.minute.ago)

      described_class.check(stream)
      expect { described_class.check(stream) }.not_to change(Anomaly, :count)
    end

    it "returns array of created anomaly IDs" do
      make_estimate(percent: 80, timestamp: 12.minutes.ago)
      make_estimate(percent: 60, timestamp: 1.minute.ago)

      ids = described_class.check(stream)
      expect(ids).to be_an(Array)
      expect(ids.first).to be_a(String)
      expect(Anomaly.find(ids.first).anomaly_type).to eq("erv_divergence")
    end

    it "ignores estimates outside 15min window" do
      make_estimate(percent: 80, timestamp: 20.minutes.ago)  # outside window
      make_estimate(percent: 60, timestamp: 1.minute.ago)

      # Only 1 estimate inside window → no-op
      expect { described_class.check(stream) }.not_to change(Anomaly, :count)
    end
  end
end
