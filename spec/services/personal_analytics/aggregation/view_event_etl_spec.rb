# frozen_string_literal: true

require "rails_helper"

RSpec.describe PersonalAnalytics::Aggregation::ViewEventEtl do
  let(:user) { create(:user) }

  def stream_view(channel_id:, watched_at:, duration_sec: 600, **extra)
    payload = { channel_id: channel_id, watched_at: watched_at.iso8601, duration_sec: duration_sec }.merge(extra)
    create(:sync_event, user: user, event_type: "stream_view", payload: payload, synced_at: watched_at)
  end

  it "ETLs stream_view SyncEvents into pva_view_events keyed by source_event_hash" do
    sync_event = stream_view(channel_id: "555", watched_at: Time.utc(2026, 5, 20, 20, 0, 0))

    dates = described_class.call(user.id)

    expect(PvaViewEvent.where(user_id: user.id).count).to eq(1)
    row = PvaViewEvent.find_by(user_id: user.id)
    expect(row.twitch_channel_id).to eq("555")
    expect(row.source_event_hash).to eq(sync_event.event_hash)
    expect(row.seconds).to eq(600)
    expect(dates).to contain_exactly(Date.new(2026, 5, 20))
  end

  it "is idempotent — re-running does not duplicate (UNIQUE source_event_hash)" do
    stream_view(channel_id: "555", watched_at: Time.utc(2026, 5, 20, 20, 0, 0))

    described_class.call(user.id)
    described_class.call(user.id)

    expect(PvaViewEvent.where(user_id: user.id).count).to eq(1)
  end

  it "enriches channel_id/twitch_login for tracked channels, leaves nil for untracked" do
    channel = create(:channel, twitch_id: "555", login: "xqc")
    stream_view(channel_id: "555", watched_at: Time.utc(2026, 5, 20, 20, 0, 0))
    stream_view(channel_id: "999", watched_at: Time.utc(2026, 5, 20, 21, 0, 0))

    described_class.call(user.id)

    tracked = PvaViewEvent.find_by(twitch_channel_id: "555")
    untracked = PvaViewEvent.find_by(twitch_channel_id: "999")
    expect(tracked.channel_id).to eq(channel.id)
    expect(tracked.twitch_login).to eq("xqc")
    expect(untracked.channel_id).to be_nil
    expect(untracked.twitch_login).to be_nil
  end

  it "clamps an unknown device to nil (raw insert bypasses model validation)" do
    stream_view(channel_id: "555", watched_at: Time.utc(2026, 5, 20, 20, 0, 0), device: "smart_fridge")

    described_class.call(user.id)

    expect(PvaViewEvent.find_by(user_id: user.id).device).to be_nil
  end

  it "ignores non-stream_view sync events" do
    create(:sync_event, user: user, event_type: "login", payload: {}, synced_at: Time.current)

    expect(described_class.call(user.id)).to be_empty
    expect(PvaViewEvent.where(user_id: user.id)).to be_empty
  end
end
