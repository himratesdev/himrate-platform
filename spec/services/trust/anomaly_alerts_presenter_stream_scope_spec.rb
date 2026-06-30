# frozen_string_literal: true

require "rails_helper"

# T2-020: AnomalyAlertsPresenter generalization — explicit `stream:` + `window: nil` (used by
# StreamBreakdown to present a SPECIFIC stream's full anomaly history, incl. past streams, not just
# the channel's current live stream within the last 5 minutes). Default behavior is covered by
# anomaly_alerts_presenter_spec.rb (channel live_stream + WINDOW).
RSpec.describe Trust::AnomalyAlertsPresenter, "stream-scoped" do
  let(:channel) { create(:channel) }

  it "presents anomalies for an explicit past stream with window: nil (whole-stream history)" do
    past = create(:stream, channel: channel, started_at: 3.days.ago, ended_at: 3.days.ago + 2.hours,
      game_name: "Just Chatting")
    # Anomaly older than the default 5-minute WINDOW — must still surface when window is nil.
    Anomaly.create!(stream: past, timestamp: 3.days.ago + 1.hour, anomaly_type: "ccv_step_function",
      confidence: 0.9, details: { "signal_value" => 3.0 })

    alerts = described_class.new(channel: channel, stream: past, window: nil).call

    expect(alerts.map { |a| a[:type] }).to include("ccv_spike")
  end

  it "defaults to the channel's live stream when no explicit stream is given (backward compatible)" do
    live = create(:stream, channel: channel, started_at: 1.hour.ago, ended_at: nil, game_name: "Just Chatting")
    Anomaly.create!(stream: live, timestamp: 1.minute.ago, anomaly_type: "ccv_step_function",
      confidence: 0.9, details: { "signal_value" => 3.0 })

    alerts = described_class.new(channel: channel).call

    expect(alerts.map { |a| a[:type] }).to include("ccv_spike")
  end
end
