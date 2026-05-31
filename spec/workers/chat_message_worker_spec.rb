# frozen_string_literal: true

require "rails_helper"

# PR 1e-A (2026-05-31): post-CH-cutover ChatMessageWorker writes ONLY to ClickHouse.
# All assertions on `ChatMessage.count` / `ChatMessage.last` were removed — Postgres
# is no longer a writer for chat (PG chat_messages table dropped in PR 1e-B). The new
# contract is captured by spying on `Clickhouse.client.insert`: the worker must call
# it with the expected rows for each Redis batch, must raise (not swallow) on CH
# failure, and must re-queue the drained batch back to Redis when it does.
RSpec.describe ChatMessageWorker do
  let(:worker) { described_class.new }
  let(:redis_url) { "redis://localhost:6379/1" }
  let(:redis_key) { "irc:chat_messages" }
  let(:ch_client) { instance_double(Clickhouse::Client) }
  let(:captured_rows) { [] }

  before do
    allow(ENV).to receive(:fetch).and_call_original
    allow(ENV).to receive(:fetch).with("REDIS_URL", anything).and_return(redis_url)

    # Spy on the (now primary) CH write path. Default: succeed and capture the rows.
    allow(Clickhouse).to receive(:client).and_return(ch_client)
    allow(ch_client).to receive(:insert) { |_table, rows| captured_rows.replace(rows) }

    # Clear Redis queue
    Redis.new(url: redis_url).del(redis_key)
  rescue Redis::CannotConnectError
    skip "Redis not available"
  end

  def push_message(data)
    Redis.new(url: redis_url).lpush(redis_key, JSON.generate(data))
  end

  def sample_message(overrides = {})
    {
      channel_login: "testchannel",
      username: "testuser",
      message_text: "Hello world",
      msg_type: "privmsg",
      display_name: "TestUser",
      subscriber_status: "1",
      badge_info: "subscriber/12",
      is_first_msg: false,
      returning_chatter: true,
      emotes: nil,
      user_type: nil,
      vip: false,
      color: "#FF0000",
      bits_used: 0,
      twitch_msg_id: "msg-123",
      raw_tags: { "display-name" => "TestUser", "subscriber" => "1" },
      timestamp: Time.current.iso8601
    }.merge(overrides)
  end

  describe "#perform" do
    # TC-013 (post-cutover): Redis → ClickHouse insert
    it "writes Redis-drained messages into the ClickHouse chat_messages table" do
      push_message(sample_message)
      push_message(sample_message(username: "user2", message_text: "Second msg"))

      worker.perform

      expect(ch_client).to have_received(:insert).with("chat_messages", anything)
      expect(captured_rows.size).to eq(2)
      # Row shape (Clickhouse::ChatRow.from_pg) — verify the dimensions a downstream
      # signal/aggregation actually consumes survive the transform.
      expect(captured_rows.map { |r| r[:channel_login] }).to all(eq("testchannel"))
      expect(captured_rows.map { |r| r[:username] }).to match_array([ "testuser", "user2" ])
      expect(captured_rows.map { |r| r[:msg_type] }).to all(eq("privmsg"))
      expect(captured_rows.first[:raw_tags]).to be_a(String) # JSON serialized for CH
    end

    it "is a no-op when the Redis queue is empty" do
      worker.perform
      expect(ch_client).not_to have_received(:insert)
    end

    it "skips invalid JSON and writes the rest" do
      Redis.new(url: redis_url).lpush(redis_key, "not-json{{{")
      push_message(sample_message)

      worker.perform

      expect(captured_rows.size).to eq(1)
      expect(captured_rows.first[:username]).to eq("testuser")
    end

    it "writes USERNOTICE messages with the right msg_type and raw_tags" do
      push_message(sample_message(
        msg_type: "sub",
        message_text: "PogChamp first sub!",
        raw_tags: { "msg-id" => "sub", "msg-param-cumulative-months" => "1" }
      ))

      worker.perform

      row = captured_rows.first
      expect(row[:msg_type]).to eq("sub")
      expect(JSON.parse(row[:raw_tags])["msg-param-cumulative-months"]).to eq("1")
    end

    it "writes ROOMSTATE messages" do
      push_message(sample_message(
        msg_type: "roomstate",
        username: nil,
        message_text: nil,
        raw_tags: { "followers-only" => "10", "slow" => "30" }
      ))

      worker.perform

      row = captured_rows.first
      expect(row[:msg_type]).to eq("roomstate")
      expect(JSON.parse(row[:raw_tags])["followers-only"]).to eq("10")
    end

    it "writes CLEARCHAT messages" do
      push_message(sample_message(
        msg_type: "clearchat",
        username: "banneduser",
        message_text: nil,
        raw_tags: { "ban-duration" => "600" }
      ))

      worker.perform

      row = captured_rows.first
      expect(row[:msg_type]).to eq("clearchat")
      expect(JSON.parse(row[:raw_tags])["ban-duration"]).to eq("600")
    end

    it "resolves stream_id from the active stream for channel_login" do
      channel = create(:channel, login: "testchannel")
      stream = create(:stream, channel: channel, ended_at: nil)

      push_message(sample_message)
      worker.perform

      expect(captured_rows.first[:stream_id]).to eq(stream.id)
    end

    it "writes nil stream_id when no active stream exists for the channel" do
      push_message(sample_message(channel_login: "nochannel"))
      worker.perform

      expect(captured_rows.first[:stream_id]).to be_nil
    end

    # PR 1e-A: post-cutover CH is the SoT — a write failure MUST raise (no best_effort)
    # so Sidekiq retry kicks in. Re-queue contract from the PG era is preserved verbatim.
    it "re-queues the drained batch and re-raises on a ClickHouse insert failure" do
      push_message(sample_message)
      allow(ch_client).to receive(:insert).and_raise(Clickhouse::QueryError, "boom")

      expect { worker.perform }.to raise_error(Clickhouse::QueryError)
      expect(Redis.new(url: redis_url).llen(redis_key)).to eq(1) # restored, not lost
    end
  end
end
