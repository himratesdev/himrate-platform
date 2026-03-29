# frozen_string_literal: true

require "rails_helper"

RSpec.describe StreamOfflineWorker do
  let(:worker) { described_class.new }
  let(:channel) { create(:channel, twitch_id: "12345", login: "teststreamer") }

  before do
    allow(ENV).to receive(:fetch).and_call_original
    allow(ENV).to receive(:fetch).with("REDIS_URL", anything).and_return("redis://localhost:6379/1")
  end

  let(:event_data) do
    { "broadcaster_user_id" => channel.twitch_id, "broadcaster_user_login" => channel.login }
  end

  # TC-006: Finalize Stream
  it "finalizes Stream with peak_ccv, avg_ccv, duration_ms" do
    stream = create(:stream, channel: channel, started_at: 2.hours.ago, ended_at: nil)
    create(:ccv_snapshot, stream: stream, timestamp: 1.hour.ago, ccv_count: 100)
    create(:ccv_snapshot, stream: stream, timestamp: 30.minutes.ago, ccv_count: 200)
    create(:ccv_snapshot, stream: stream, timestamp: 10.minutes.ago, ccv_count: 150)

    worker.perform(event_data)

    stream.reload
    expect(stream.ended_at).to be_present
    expect(stream.peak_ccv).to eq(200)
    expect(stream.avg_ccv).to eq(150)
    expect(stream.duration_ms).to be > 0
  end

  # TC-007: No active stream → warning
  it "logs warning if no active stream found" do
    expect(Rails.logger).to receive(:warn).with(/no active stream/)
    worker.perform(event_data)
  end
end
