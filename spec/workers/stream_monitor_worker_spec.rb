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
      [ { "data" => { "user" => { "stream" => { "viewersCount" => 500 } } } } ]
    )
    # BUG-251.30: CommunityTab batch — default empty so existing CCV/chat tests are
    # unaffected. Dedicated specs below stub specific responses.
    allow(gql).to receive(:batch).with(array_including(hash_including(query: /CommunityTab/))).and_return(
      [ { "data" => { "channel" => { "chatters" => nil } } } ]
    )
    # TASK-251.6: chatters now come from chat_messages, not GQL ChattersCount.

    # Tier 2 stubs
    allow(gql).to receive(:chat_room_state).and_return(nil)
    allow(gql).to receive(:predictions).and_return(nil)
    allow(gql).to receive(:polls).and_return(nil)
    allow(gql).to receive(:hype_train).and_return(nil)

    Redis.new(url: "redis://localhost:6379/1").del("monitor:cycle_count")
  rescue Redis::CannotConnectError
    skip "Redis not available"
  end

  before do
    # Ensure no leaked active streams from other specs
    Stream.where(ended_at: nil).where.not(id: stream.id).update_all(ended_at: Time.current)
  end

  # TC-008: CCV snapshot
  it "creates ccv_snapshot for active stream" do
    expect { worker.perform }.to change { stream.ccv_snapshots.count }.by(1)

    snapshot = stream.ccv_snapshots.order(timestamp: :desc).first
    expect(snapshot.ccv_count).to eq(500)
  end

  # TC-009: Chatters snapshot from captured chat (TASK-251.6 — unique chatters + messages)
  it "creates chatters_snapshot from captured chat" do
    %w[alice bob carol alice].each do |u| # 3 unique, 4 messages
      create(:chat_message, stream: stream, channel_login: "teststreamer", username: u, timestamp: Time.current)
    end

    expect { worker.perform }.to change { stream.chatters_snapshots.count }.by(1)

    snapshot = stream.chatters_snapshots.order(timestamp: :desc).first
    expect(snapshot.unique_chatters_count).to eq(3)
    expect(snapshot.total_messages_count).to eq(4)
    expect(snapshot.auth_ratio.to_f).to be_within(0.0001).of(3.0 / 500) # ccv 500 from StreamMetadata stub
  end

  # BUG-251.24 regression: bursty chat (60-min unique chatters >> instantaneous CCV) → ratio > 1.
  # Pre-migration this raised ActiveRecord::RangeError on numeric(5,4) overflow when ratio ≥ 10.
  # Post-migration the wider numeric(8,4) column accepts values up to 9999.9999 → row saves cleanly.
  it "stores auth_ratio when bursty chat pushes the ratio above 1.0 (numeric(8,4))" do
    # Low instantaneous CCV
    allow(gql).to receive(:batch).with(array_including(hash_including(query: /StreamMetadata/))).and_return(
      [ { "data" => { "user" => { "stream" => { "viewersCount" => 5 } } } } ]
    )
    # Many unique chatters over the 60-min window → unique=50, ratio = 50/5 = 10.0
    50.times do |i|
      create(:chat_message, stream: stream, channel_login: "teststreamer", username: "user_#{i}", timestamp: Time.current)
    end

    expect { worker.perform }.to change { stream.chatters_snapshots.count }.by(1)

    snapshot = stream.chatters_snapshots.order(timestamp: :desc).first
    expect(snapshot.unique_chatters_count).to eq(50)
    expect(snapshot.auth_ratio.to_f).to be_within(0.0001).of(10.0)
  end

  # BUG-251.30: populate chatters_present_total + viewer_logins from CommunityTab batch.
  it "persists CommunityTab presence (chatters_present_total + role breakdown + viewer_logins)" do
    allow(gql).to receive(:batch).with(array_including(hash_including(query: /CommunityTab/))).and_return(
      [ { "data" => { "channel" => { "chatters" => {
        "broadcasters" => [ { "login" => "teststreamer" } ],
        "moderators" => [ { "login" => "mod1" }, { "login" => "mod2" } ],
        "vips" => [ { "login" => "vip1" } ],
        "staff" => [],
        "viewers" => [ { "login" => "v1" }, { "login" => "v2" }, { "login" => "v3" } ],
        "count" => 7
      } } } } ]
    )

    expect { worker.perform }.to change { stream.chatters_snapshots.count }.by(1)

    snapshot = stream.chatters_snapshots.order(timestamp: :desc).first
    expect(snapshot.chatters_present_total).to eq(7) # 1+2+1+0+3
    expect(snapshot.broadcasters_count).to eq(1)
    expect(snapshot.moderators_count).to eq(2)
    expect(snapshot.vips_count).to eq(1)
    expect(snapshot.staff_count).to eq(0)
    expect(snapshot.viewers_count_present).to eq(3)
    expect(snapshot.viewer_logins).to eq(%w[teststreamer mod1 mod2 vip1 v1 v2 v3])
  end

  # BUG-251.30: presence-only path (no IRC chat captured) still writes ChattersSnapshot.
  it "saves snapshot when only presence (no IRC chat) — null-safe active-typer columns" do
    allow(gql).to receive(:batch).with(array_including(hash_including(query: /CommunityTab/))).and_return(
      [ { "data" => { "channel" => { "chatters" => {
        "broadcasters" => [ { "login" => "teststreamer" } ],
        "moderators" => [], "vips" => [], "staff" => [],
        "viewers" => [ { "login" => "lurker1" } ],
        "count" => 2
      } } } } ]
    )

    expect { worker.perform }.to change { stream.chatters_snapshots.count }.by(1)

    snapshot = stream.chatters_snapshots.order(timestamp: :desc).first
    expect(snapshot.chatters_present_total).to eq(2)
    expect(snapshot.unique_chatters_count).to eq(0)
    expect(snapshot.total_messages_count).to eq(0)
    expect(snapshot.auth_ratio).to be_nil # no IRC typers
  end

  # BUG-251.30: CommunityTab batch failure does NOT break CCV/chat persistence — graceful.
  it "tolerates community_tab batch error — CCV/chat persistence unaffected" do
    allow(gql).to receive(:batch).with(array_including(hash_including(query: /CommunityTab/))).and_raise(
      Twitch::GqlClient::Error, "community_tab batch down"
    )
    create(:chat_message, stream: stream, channel_login: "teststreamer", username: "u1", timestamp: Time.current)

    expect { worker.perform }.to change { stream.ccv_snapshots.count }.by(1)
      .and change { stream.chatters_snapshots.count }.by(1)

    snapshot = stream.chatters_snapshots.order(timestamp: :desc).first
    expect(snapshot.chatters_present_total).to be_nil
    expect(snapshot.unique_chatters_count).to eq(1)
  end

  # TC-011: Helix fallback
  it "falls back to Helix when GQL fails" do
    allow(gql).to receive(:batch).with(array_including(hash_including(query: /StreamMetadata/))).and_raise(Twitch::GqlClient::Error, "GQL down")
    allow(helix).to receive(:get_streams).and_return([ { "user_login" => "teststreamer", "viewer_count" => 300 } ])

    expect { worker.perform }.to change { stream.ccv_snapshots.count }.by(1)
    expect(stream.ccv_snapshots.order(timestamp: :desc).first.ccv_count).to eq(300)
  end

  # TC-012: Tier 2 ChatRoomState
  it "updates ChatRoomState on Tier 2 cycle" do
    allow(gql).to receive(:chat_room_state).and_return({
      followers_only_duration_minutes: 10,
      slow_mode_duration_seconds: 30,
      emote_only_mode: false,
      subscriber_only_mode: false,
      email_verification_mode: "REQUIRED",
      phone_verification_mode: "REQUIRED",
      minimum_account_age_minutes: 1440,
      restrict_first_timers: true
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
    expect { worker.perform }.to change { stream.predictions_polls.count }.by(1)

    record = stream.predictions_polls.order(timestamp: :desc).first
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
    expect { worker.perform }.to change { stream.predictions_polls.count }.by(1)
    expect(stream.predictions_polls.order(timestamp: :desc).first.event_type).to eq("poll")
  end

  # TC-015: Tier 2 HypeTrain
  it "saves hype train on Tier 2 cycle" do
    create(:ccv_snapshot, stream: stream, ccv_count: 1000)
    allow(gql).to receive(:hype_train).and_return({
      id: "ht-1", level: 3, progress: 8000, goal: 10000, conductors_count: 45
    })

    Redis.new(url: "redis://localhost:6379/1").set("monitor:cycle_count", 4)
    expect { worker.perform }.to change { stream.predictions_polls.count }.by(1)
    expect(stream.predictions_polls.order(timestamp: :desc).first.event_type).to eq("hype_train")
  end

  # TC-016: Skip inactive
  it "skips when no active predictions/polls" do
    Redis.new(url: "redis://localhost:6379/1").set("monitor:cycle_count", 4)
    expect { worker.perform }.not_to change { stream.predictions_polls.count }
  end

  # TC-019: Stateless
  it "reads active streams from DB each cycle (stateless)" do
    worker.perform
    expect(stream.ccv_snapshots.count).to be >= 1
  end

  it "skips when Flipper disabled" do
    allow(Flipper).to receive(:enabled?).with(:stream_monitor).and_return(false)
    expect { worker.perform }.not_to change { stream.ccv_snapshots.count }
  end

  it "skips when no active streams" do
    Stream.where(ended_at: nil).update_all(ended_at: Time.current)
    expect { worker.perform }.not_to change { CcvSnapshot.count }
  end
end
