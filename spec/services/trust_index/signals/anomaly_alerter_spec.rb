# frozen_string_literal: true

require "rails_helper"

RSpec.describe TrustIndex::Signals::AnomalyAlerter do
  let(:channel) { Channel.create!(twitch_id: "alert_ch", login: "alert_channel", display_name: "Alert") }
  let(:stream) { Stream.create!(channel: channel, started_at: 1.hour.ago) }

  before do
    SignalConfiguration.find_or_create_by!(
      signal_type: "auth_ratio", category: "default", param_name: "alert_threshold"
    ) { |c| c.param_value = 0.5 }
  end

  def make_result(value:, confidence: 1.0, metadata: {})
    TrustIndex::Signals::BaseSignal::Result.new(value: value, confidence: confidence, metadata: metadata)
  end

  it "creates anomaly when value > threshold AND confidence >= 0.7" do
    results = { "auth_ratio" => make_result(value: 0.8, confidence: 0.9) }

    expect { described_class.check(stream, results) }.to change(Anomaly, :count).by(1)

    anomaly = Anomaly.last
    expect(anomaly.anomaly_type).to eq("auth_ratio")
    expect(anomaly.confidence).to eq(0.9)
    expect(anomaly.details["signal_value"]).to be_within(0.01).of(0.8)
  end

  it "skips when confidence < 0.7" do
    results = { "auth_ratio" => make_result(value: 0.8, confidence: 0.5) }
    expect { described_class.check(stream, results) }.not_to change(Anomaly, :count)
  end

  it "skips when value <= threshold" do
    results = { "auth_ratio" => make_result(value: 0.3, confidence: 0.9) }
    expect { described_class.check(stream, results) }.not_to change(Anomaly, :count)
  end

  it "deduplicates within 5 min window" do
    results = { "auth_ratio" => make_result(value: 0.8, confidence: 0.9) }
    described_class.check(stream, results)
    expect { described_class.check(stream, results) }.not_to change(Anomaly, :count)
  end

  it "skips nil values" do
    results = { "auth_ratio" => make_result(value: nil, confidence: 1.0) }
    expect { described_class.check(stream, results) }.not_to change(Anomaly, :count)
  end
end
