# frozen_string_literal: true

require "rails_helper"

RSpec.describe Farm::CaptureChatDrainWorker do
  let(:redis_url) { "redis://localhost:6379/1" }
  let(:redis) { Redis.new(url: redis_url) }
  let(:queue_key) { described_class::QUEUE_KEY }
  let(:ch_client) { instance_double(Clickhouse::Client) }
  let(:inserts) { [] }

  before do
    allow(ENV).to receive(:fetch).and_call_original
    allow(ENV).to receive(:fetch).with("REDIS_URL", anything).and_return(redis_url)
    allow(Clickhouse).to receive(:client).and_return(ch_client)
    allow(ch_client).to receive(:insert) { |table, rows| inserts << [ table, rows ]; rows.size }
    redis.del(queue_key, Farm::CaptureSet::SET_KEY)
    redis.hset(Farm::CaptureSet::SET_KEY, "pubgguy", { "game_id" => "493057" }.to_json)
  rescue Redis::CannotConnectError
    skip "Redis not available"
  end

  after { redis.del(queue_key, Farm::CaptureSet::SET_KEY) rescue nil }

  def push(overrides = {})
    record = {
      stream_id: nil, channel_login: "pubgguy", username: "viewer1", message_text: "gg", msg_type: "privmsg",
      display_name: "Viewer1", subscriber_status: "0", badge_info: nil, is_first_msg: false, returning_chatter: false,
      emotes: nil, user_type: nil, vip: false, color: "#FF0000", bits_used: 0, twitch_msg_id: "m1",
      raw_tags: { "id" => "m1" }, timestamp: "2026-09-05T12:00:00.123Z"
    }.merge(overrides)
    redis.lpush(queue_key, JSON.generate(record))
  end

  it "drains the queue into capture_chat_messages with game_id stamped and no stream_id" do
    push
    push(channel_login: "unknown_chan", twitch_msg_id: "m2")

    described_class.new.perform

    expect(redis.llen(queue_key)).to eq(0)
    expect(inserts.size).to eq(1)
    table, rows = inserts.first
    expect(table).to eq("capture_chat_messages")
    expect(rows.size).to eq(2)
    by_id = rows.index_by { |r| r[:twitch_msg_id] }
    expect(by_id["m1"]).to include(game_id: "493057", channel_login: "pubgguy", username: "viewer1",
                                   msg_type: "privmsg", timestamp: "2026-09-05 12:00:00.123", vip: 0)
    expect(by_id["m1"]).not_to have_key(:stream_id)
    expect(by_id["m2"][:game_id]).to eq("") # login absent from the set → empty, never a PG lookup
    expect(by_id["m1"][:raw_tags]).to eq({ "id" => "m1" }.to_json)
  end

  it "re-queues the batch and raises when the ClickHouse insert fails (nothing lost)" do
    push
    allow(ch_client).to receive(:insert).and_raise(Clickhouse::ConnectionError, "down")

    expect { described_class.new.perform }.to raise_error(Clickhouse::ConnectionError)
    expect(redis.llen(queue_key)).to eq(1)
  end

  it "skips malformed JSON entries without dropping valid ones" do
    push
    redis.lpush(queue_key, "not json")

    described_class.new.perform

    expect(inserts.first.last.size).to eq(1)
  end

  it "is a no-op on an empty queue (no CH call, no set read)" do
    expect(Farm::CaptureSet).not_to receive(:new)
    described_class.new.perform
    expect(inserts).to be_empty
  end
end
