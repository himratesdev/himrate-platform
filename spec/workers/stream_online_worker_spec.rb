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
end
