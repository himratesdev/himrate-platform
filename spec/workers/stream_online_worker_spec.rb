# frozen_string_literal: true

require "rails_helper"

RSpec.describe StreamOnlineWorker do
  let(:worker) { described_class.new }
  let(:channel) { create(:channel, twitch_id: "12345", login: "teststreamer") }

  before do
    allow(ENV).to receive(:fetch).and_call_original
    allow(ENV).to receive(:fetch).with("REDIS_URL", anything).and_return("redis://localhost:6379/1")

    stub_request(:post, "https://gql.twitch.tv/gql")
      .to_return(status: 200, body: { data: { user: { stream: nil, broadcastSettings: { title: "Test", language: "en", game: { name: "Just Chatting", id: "509658" } } } } }.to_json,
                 headers: { "Content-Type" => "application/json" })

    # Clear Redis pub/sub (no-op needed)
  end

  let(:event_data) do
    {
      "broadcaster_user_id" => channel.twitch_id,
      "broadcaster_user_login" => channel.login,
      "started_at" => Time.current.iso8601,
      "type" => "live"
    }
  end

  # TC-001: Creates Stream record
  it "creates a Stream record on stream.online" do
    expect { worker.perform(event_data) }.to change(Stream, :count).by(1)

    stream = channel.streams.order(created_at: :desc).first
    expect(stream.channel).to eq(channel)
    expect(stream.started_at).to be_present
    expect(stream.ended_at).to be_nil
  end

  # TC-002: Auto-creates Channel
  it "auto-creates Channel if not found" do
    event = event_data.merge("broadcaster_user_id" => "99999", "broadcaster_user_login" => "newstreamer")

    expect { worker.perform(event) }.to change(Channel, :count).by(1)
    expect(Channel.find_by(twitch_id: "99999").login).to eq("newstreamer")
  end

  # TC-003: Duplicate → skip
  it "skips if active stream already exists" do
    create(:stream, channel: channel, ended_at: nil)

    expect { worker.perform(event_data) }.not_to change(Stream, :count)
  end

  # TC-004: Stream merge
  it "merges with previous stream if <30min gap and same category" do
    old_stream = create(:stream, channel: channel, ended_at: 10.minutes.ago, game_name: "Just Chatting")
    event = event_data.merge("category_name" => "Just Chatting")

    expect { worker.perform(event) }.not_to change(Stream, :count)

    old_stream.reload
    expect(old_stream.ended_at).to be_nil
    expect(old_stream.merge_status).to eq("merged")
  end

  # TC-005: No merge (different category)
  it "creates new stream if category changed" do
    create(:stream, channel: channel, ended_at: 10.minutes.ago, game_name: "Fortnite")
    event = event_data.merge("category_name" => "Just Chatting")

    expect { worker.perform(event) }.to change(Stream, :count).by(1)
  end

  # TASK-033 TC-004: Merge increments merged_parts_count and records part_boundaries
  it "increments merged_parts_count and records part_boundaries on merge" do
    old_stream = create(:stream, channel: channel, started_at: 2.hours.ago, ended_at: 10.minutes.ago,
      game_name: "Just Chatting", merged_parts_count: 1, part_boundaries: [])

    create(:trust_index_history,
      channel: channel, stream: old_stream,
      trust_index_score: 65.0, erv_percent: 65.0, ccv: 3000,
      confidence: 0.8, classification: "needs_review", cold_start_status: "full",
      signal_breakdown: {}, calculated_at: 11.minutes.ago)

    worker.perform(event_data)

    old_stream.reload
    expect(old_stream.merged_parts_count).to eq(2)
    expect(old_stream.part_boundaries.size).to eq(1)
    expect(old_stream.part_boundaries.first["ti_score"]).to eq(65.0)
  end

  # TASK-033 TC-005: =30min → NOT merge
  it "does NOT merge when gap is exactly 30 minutes" do
    create(:stream, channel: channel, started_at: 2.hours.ago, ended_at: 30.minutes.ago,
      game_name: "Just Chatting")

    expect { worker.perform(event_data) }.to change(Stream, :count).by(1)
  end

  # TASK-033 TC-007: 3 reconnects → parts_count=3, 2 boundaries
  it "handles multiple reconnects with cumulative part_boundaries" do
    old_stream = create(:stream, channel: channel, started_at: 3.hours.ago, ended_at: 10.minutes.ago,
      game_name: "Just Chatting", merged_parts_count: 2,
      part_boundaries: [ { "ended_at" => 1.hour.ago.iso8601, "ti_score" => 60.0, "erv_percent" => 60.0, "part_number" => 1 } ])

    create(:trust_index_history,
      channel: channel, stream: old_stream,
      trust_index_score: 70.0, erv_percent: 70.0, ccv: 4000,
      confidence: 0.85, classification: "needs_review", cold_start_status: "full",
      signal_breakdown: {}, calculated_at: 11.minutes.ago)

    worker.perform(event_data)

    old_stream.reload
    expect(old_stream.merged_parts_count).to eq(3)
    expect(old_stream.part_boundaries.size).to eq(2)
  end

  # TASK-033: nil game_name fallback — both nil → merge
  it "merges when both game_names are nil (GQL failure)" do
    old_stream = create(:stream, channel: channel, ended_at: 10.minutes.ago, game_name: nil)

    # Stub GQL to return nil game
    stub_request(:post, "https://gql.twitch.tv/gql")
      .to_return(status: 200, body: { data: { user: { stream: nil, broadcastSettings: { title: "Test", language: "en", game: nil } } } }.to_json,
                 headers: { "Content-Type" => "application/json" })

    expect { worker.perform(event_data) }.not_to change(Stream, :count)
    old_stream.reload
    expect(old_stream.merge_status).to eq("merged")
  end
end
