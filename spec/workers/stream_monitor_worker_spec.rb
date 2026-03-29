# frozen_string_literal: true

require "rails_helper"

RSpec.describe StreamMonitorWorker do
  let(:worker) { described_class.new }
  let(:channel) { create(:channel, twitch_id: "12345", login: "teststreamer") }
  let!(:stream) { create(:stream, channel: channel, ended_at: nil) }
  let(:gql) { instance_double(Twitch::GqlClient) }
  let(:helix) { instance_double(Twitch::HelixClient) }

  before do
    allow(ENV).to receive(:fetch).and_call_original
    allow(ENV).to receive(:fetch).with("REDIS_URL", anything).and_return("redis://localhost:6379/1")
    allow(Flipper).to receive(:enabled?).with(:stream_monitor).and_return(true)
    allow(Twitch::GqlClient).to receive(:new).and_return(gql)
    allow(Twitch::HelixClient).to receive(:new).and_return(helix)

    # Default batch stubs
    allow(gql).to receive(:batch).with(array_including(hash_including(query: /StreamMetadata/))).and_return(
      [{ "data" => { "user" => { "stream" => { "viewersCount" => 500 } } } }]
    )
    allow(gql).to receive(:batch).with(array_including(hash_including(query: /ChattersCount/))).and_return(
      [{ "data" => { "channel" => { "chatters" => { "count" => 400 } } } }]
    )

    # Tier 2 stubs
    allow(gql).to receive(:chat_room_state).and_return(nil)
    allow(gql).to receive(:predictions).and_return(nil)
    allow(gql).to receive(:polls).and_return(nil)
    allow(gql).to receive(:hype_train).and_return(nil)

    Redis.new(url: "redis://localhost:6379/1").del("monitor:cycle_count")
  rescue Redis::CannotConnectError
    skip "Redis not available"
  end

  # TC-008: CCV snapshot
  it "creates ccv_snapshot for active stream" do
    expect { worker.perform }.to change(CcvSnapshot, :count).by(1)

    snapshot = CcvSnapshot.last
    expect(snapshot.stream).to eq(stream)
    expect(snapshot.ccv_count).to eq(500)
  end

  # TC-009: Chatters snapshot with auth_ratio
  it "creates chatters_snapshot with auth_ratio" do
    expect { worker.perform }.to change(ChattersSnapshot, :count).by(1)

    snapshot = ChattersSnapshot.last
    expect(snapshot.unique_chatters_count).to eq(400)
    expect(snapshot.auth_ratio.to_f).to be_within(0.01).of(0.8)
  end

  # TC-011: Helix fallback
  it "falls back to Helix when GQL fails" do
    allow(gql).to receive(:batch).with(array_including(hash_including(query: /StreamMetadata/))).and_raise(Twitch::GqlClient::Error, "GQL down")
    allow(helix).to receive(:get_streams).and_return([{ "user_login" => "teststreamer", "viewer_count" => 300 }])

    expect { worker.perform }.to change(CcvSnapshot, :count).by(1)
    expect(CcvSnapshot.last.ccv_count).to eq(300)
  end

  # TC-012: Tier 2 ChatRoomState
  it "updates ChatRoomState on Tier 2 cycle" do
    allow(gql).to receive(:chat_room_state).and_return({
      followers_only_duration_minutes: 10,
      slow_mode_duration_seconds: 30,
      emote_only_mode: false,
      subscriber_only_mode: false,
      require_verified_account: true
    })

    Redis.new(url: "redis://localhost:6379/1").set("monitor:cycle_count", 4)
    worker.perform

    config = channel.reload.channel_protection_config
    expect(config).to be_present
    expect(config.followers_only_duration_min).to eq(10)
    expect(config.slow_mode_seconds).to eq(30)
    expect(config.email_verification_required).to be true
  end

  # TC-013: Tier 2 Predictions
  it "saves prediction participation on Tier 2 cycle" do
    create(:ccv_snapshot, stream: stream, ccv_count: 1000)
    allow(gql).to receive(:predictions).and_return({
      id: "pred-1", title: "Will we win?", total_users: 200, total_points: 50000, outcomes: []
    })

    Redis.new(url: "redis://localhost:6379/1").set("monitor:cycle_count", 4)
    expect { worker.perform }.to change(PredictionsPoll, :count).by(1)

    record = PredictionsPoll.last
    expect(record.event_type).to eq("prediction")
    expect(record.participants_count).to eq(200)
  end

  # TC-014: Tier 2 Polls
  it "saves poll participation on Tier 2 cycle" do
    create(:ccv_snapshot, stream: stream, ccv_count: 1000)
    allow(gql).to receive(:polls).and_return({
      id: "poll-1", title: "Fav game?", total_voters: 150, choices: []
    })

    Redis.new(url: "redis://localhost:6379/1").set("monitor:cycle_count", 4)
    expect { worker.perform }.to change(PredictionsPoll, :count).by(1)
    expect(PredictionsPoll.last.event_type).to eq("poll")
  end

  # TC-015: Tier 2 HypeTrain
  it "saves hype train on Tier 2 cycle" do
    create(:ccv_snapshot, stream: stream, ccv_count: 1000)
    allow(gql).to receive(:hype_train).and_return({
      id: "ht-1", level: 3, progress: 8000, goal: 10000, conductors_count: 45
    })

    Redis.new(url: "redis://localhost:6379/1").set("monitor:cycle_count", 4)
    expect { worker.perform }.to change(PredictionsPoll, :count).by(1)
    expect(PredictionsPoll.last.event_type).to eq("hype_train")
  end

  # TC-016: Skip inactive
  it "skips when no active predictions/polls" do
    Redis.new(url: "redis://localhost:6379/1").set("monitor:cycle_count", 4)
    expect { worker.perform }.not_to change(PredictionsPoll, :count)
  end

  # TC-019: Stateless
  it "reads active streams from DB each cycle (stateless)" do
    worker.perform
    expect(CcvSnapshot.count).to be >= 1
  end

  it "skips when Flipper disabled" do
    allow(Flipper).to receive(:enabled?).with(:stream_monitor).and_return(false)
    expect { worker.perform }.not_to change(CcvSnapshot, :count)
  end

  it "skips when no active streams" do
    stream.update!(ended_at: Time.current)
    expect { worker.perform }.not_to change(CcvSnapshot, :count)
  end
end
