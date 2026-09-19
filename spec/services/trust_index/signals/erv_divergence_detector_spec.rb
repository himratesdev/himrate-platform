# frozen_string_literal: true

require "rails_helper"

# V1-RETIRE: basis = TIH.authenticity (the erv_percent heir, stream-scoped, 15min window).
# DETECTION-AUDIT 2026-09-19: the erv_estimates table the detector used to read is dropped, so the
# «ignores the retired source» guard is now structural — there is nothing left to read.
RSpec.describe TrustIndex::Signals::ErvDivergenceDetector do
  let(:channel) { Channel.create!(twitch_id: "ed_ch", login: "ed_channel", display_name: "ED") }
  let(:stream) { Stream.create!(channel: channel, started_at: 1.hour.ago) }

  def make_history(authenticity:, calculated_at:)
    TrustIndexHistory.create!(
      channel: channel, stream: stream, engine_version: "v2",
      authenticity: authenticity, calculated_at: calculated_at, cold_start_tier: "full"
    )
  end

  describe ".check" do
    it "creates erv_divergence anomaly when |delta| > 10% в 15min window" do
      make_history(authenticity: 80, calculated_at: 12.minutes.ago)
      make_history(authenticity: 60, calculated_at: 1.minute.ago)

      expect { described_class.check(stream) }.to change(Anomaly, :count).by(1)

      anomaly = Anomaly.last
      expect(anomaly.anomaly_type).to eq("erv_divergence")
      expect(anomaly.details["delta_pct"]).to be_within(0.1).of(25.0)  # |60-80|/80 = 25%
      # T1-074 surface-audit dual-emit: axis + authenticity keys alongside legacy erv_percent keys
      expect(anomaly.details["axis"]).to eq("authenticity")
      expect(anomaly.details["from_authenticity"]).to be_within(0.1).of(80.0)
      expect(anomaly.details["to_authenticity"]).to be_within(0.1).of(60.0)
      expect(anomaly.details["from_erv_percent"]).to be_within(0.1).of(80.0) # legacy keys kept
      expect(anomaly.details["to_erv_percent"]).to be_within(0.1).of(60.0)
      expect(anomaly.details["window_minutes"]).to eq(15)
    end

    it "creates anomaly также для positive divergence (authenticity jumped up)" do
      make_history(authenticity: 50, calculated_at: 12.minutes.ago)
      make_history(authenticity: 70, calculated_at: 1.minute.ago)

      expect { described_class.check(stream) }.to change(Anomaly, :count).by(1)
      expect(Anomaly.last.details["delta_pct"]).to be_within(0.1).of(40.0)  # |70-50|/50 = 40%
    end

    it "does NOT create anomaly when |delta| <= 10%" do
      make_history(authenticity: 80, calculated_at: 12.minutes.ago)
      make_history(authenticity: 75, calculated_at: 1.minute.ago)  # 6.25% delta

      expect { described_class.check(stream) }.not_to change(Anomaly, :count)
    end

    it "no-op when estimates.size < 2 (insufficient data — EC-22)" do
      make_history(authenticity: 80, calculated_at: 1.minute.ago)
      expect { described_class.check(stream) }.not_to change(Anomaly, :count)
    end

    it "no-op when baseline = 0 (avoid division by zero)" do
      make_history(authenticity: 0, calculated_at: 12.minutes.ago)
      make_history(authenticity: 50, calculated_at: 1.minute.ago)

      expect { described_class.check(stream) }.not_to change(Anomaly, :count)
    end

    it "deduplicates within 5min window (FR-016 AnomalyAlerter pattern)" do
      make_history(authenticity: 80, calculated_at: 12.minutes.ago)
      make_history(authenticity: 60, calculated_at: 1.minute.ago)

      described_class.check(stream)
      expect { described_class.check(stream) }.not_to change(Anomaly, :count)
    end

    it "returns array of created anomaly IDs" do
      make_history(authenticity: 80, calculated_at: 12.minutes.ago)
      make_history(authenticity: 60, calculated_at: 1.minute.ago)

      ids = described_class.check(stream)
      expect(ids).to be_an(Array)
      expect(ids.first).to be_a(String)
      expect(Anomaly.find(ids.first).anomaly_type).to eq("erv_divergence")
    end

    it "ignores rows outside 15min window" do
      make_history(authenticity: 80, calculated_at: 20.minutes.ago)  # outside window
      make_history(authenticity: 60, calculated_at: 1.minute.ago)

      # Only 1 row inside window → no-op
      expect { described_class.check(stream) }.not_to change(Anomaly, :count)
    end

    it "excludes GREY rows (authenticity NULL)" do
      make_history(authenticity: 90, calculated_at: 10.minutes.ago)
      TrustIndexHistory.create!(channel: channel, stream: stream, engine_version: "v2",
                                authenticity: nil, calculated_at: 1.minute.ago, cold_start_tier: "full")
      expect { described_class.check(stream) }.not_to change(Anomaly, :count)
    end
  end
end
