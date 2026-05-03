# frozen_string_literal: true

require "rails_helper"

RSpec.describe TrustIndex::Signals::TiDropDetector do
  let(:channel) { Channel.create!(twitch_id: "td_ch", login: "td_channel", display_name: "TD") }
  let(:stream) { Stream.create!(channel: channel, started_at: 1.hour.ago) }

  def make_history(score:, calculated_at:, cold_start: "full")
    TrustIndexHistory.create!(
      channel: channel, stream: stream,
      trust_index_score: score, calculated_at: calculated_at,
      cold_start_status: cold_start, confidence: 1.0
    )
  end

  describe ".check" do
    it "creates ti_drop anomaly when TI drop > 15 pts в 30min window" do
      make_history(score: 90, calculated_at: 25.minutes.ago)
      make_history(score: 70, calculated_at: 1.minute.ago)

      expect { described_class.check(stream) }.to change(Anomaly, :count).by(1)

      anomaly = Anomaly.last
      expect(anomaly.anomaly_type).to eq("ti_drop")
      expect(anomaly.details["delta_pts"]).to be_within(0.1).of(20.0)
      expect(anomaly.details["from_score"]).to be_within(0.1).of(90.0)
      expect(anomaly.details["to_score"]).to be_within(0.1).of(70.0)
      expect(anomaly.details["window_minutes"]).to eq(30)
    end

    it "does NOT create anomaly when drop <= 15 pts" do
      make_history(score: 80, calculated_at: 25.minutes.ago)
      make_history(score: 70, calculated_at: 1.minute.ago)

      expect { described_class.check(stream) }.not_to change(Anomaly, :count)
    end

    it "no-op when history.size < 2 (insufficient data — EC-19)" do
      make_history(score: 50, calculated_at: 1.minute.ago)
      expect { described_class.check(stream) }.not_to change(Anomaly, :count)
    end

    it "no-op when latest cold_start_status == 'insufficient' (ADR-085 D-6 precondition)" do
      make_history(score: 90, calculated_at: 25.minutes.ago, cold_start: "insufficient")
      make_history(score: 50, calculated_at: 1.minute.ago, cold_start: "insufficient")

      expect { described_class.check(stream) }.not_to change(Anomaly, :count)
    end

    it "deduplicates within 5min window (FR-016 AnomalyAlerter pattern)" do
      make_history(score: 90, calculated_at: 25.minutes.ago)
      make_history(score: 70, calculated_at: 1.minute.ago)

      described_class.check(stream)
      expect { described_class.check(stream) }.not_to change(Anomaly, :count)
    end

    it "returns array of created anomaly IDs" do
      make_history(score: 90, calculated_at: 25.minutes.ago)
      make_history(score: 70, calculated_at: 1.minute.ago)

      ids = described_class.check(stream)
      expect(ids).to be_an(Array)
      expect(ids.first).to be_a(String)
      expect(Anomaly.find(ids.first).anomaly_type).to eq("ti_drop")
    end

    it "ignores history outside 30min window" do
      make_history(score: 90, calculated_at: 35.minutes.ago)  # outside window
      make_history(score: 70, calculated_at: 1.minute.ago)

      # Only 1 row inside window → size < 2 → no-op
      expect { described_class.check(stream) }.not_to change(Anomaly, :count)
    end

    it "cross-stream history (channel-scoped, ADR-085 D-6 default)" do
      other_stream = Stream.create!(channel: channel, started_at: 2.hours.ago, ended_at: 1.hour.ago)
      TrustIndexHistory.create!(
        channel: channel, stream: other_stream,
        trust_index_score: 90, calculated_at: 25.minutes.ago,
        cold_start_status: "full", confidence: 1.0
      )
      TrustIndexHistory.create!(
        channel: channel, stream: stream,
        trust_index_score: 70, calculated_at: 1.minute.ago,
        cold_start_status: "full", confidence: 1.0
      )

      expect { described_class.check(stream) }.to change(Anomaly, :count).by(1)
    end
  end
end
