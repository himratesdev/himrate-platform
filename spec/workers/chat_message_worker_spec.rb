# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatMessageWorker do
  let(:worker) { described_class.new }
  let(:redis_url) { "redis://localhost:6379/1" }
  let(:redis_key) { "irc:chat_messages" }

  before do
    allow(ENV).to receive(:fetch).and_call_original
    allow(ENV).to receive(:fetch).with("REDIS_URL", anything).and_return(redis_url)

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

  # TC-013: Redis → batch INSERT
  describe "#perform" do
    it "inserts messages from Redis into chat_messages" do
      push_message(sample_message)
      push_message(sample_message(username: "user2", message_text: "Second msg"))

      expect { worker.perform }.to change(ChatMessage, :count).by(2)

      msg = ChatMessage.last
      expect(msg.channel_login).to eq("testchannel")
      expect(msg.msg_type).to eq("privmsg")
      expect(msg.raw_tags).to be_a(Hash)
    end

    it "handles empty Redis queue" do
      expect { worker.perform }.not_to change(ChatMessage, :count)
    end

    it "skips invalid JSON in queue" do
      Redis.new(url: redis_url).lpush(redis_key, "not-json{{{")
      push_message(sample_message)

      expect { worker.perform }.to change(ChatMessage, :count).by(1)
    end

    it "inserts USERNOTICE messages" do
      push_message(sample_message(
        msg_type: "sub",
        message_text: "PogChamp first sub!",
        raw_tags: { "msg-id" => "sub", "msg-param-cumulative-months" => "1" }
      ))

      worker.perform

      msg = ChatMessage.last
      expect(msg.msg_type).to eq("sub")
      expect(msg.raw_tags["msg-param-cumulative-months"]).to eq("1")
    end

    it "inserts ROOMSTATE messages" do
      push_message(sample_message(
        msg_type: "roomstate",
        username: nil,
        message_text: nil,
        raw_tags: { "followers-only" => "10", "slow" => "30" }
      ))

      worker.perform

      msg = ChatMessage.last
      expect(msg.msg_type).to eq("roomstate")
      expect(msg.raw_tags["followers-only"]).to eq("10")
    end

    it "inserts CLEARCHAT messages" do
      push_message(sample_message(
        msg_type: "clearchat",
        username: "banneduser",
        message_text: nil,
        raw_tags: { "ban-duration" => "600" }
      ))

      worker.perform

      msg = ChatMessage.last
      expect(msg.msg_type).to eq("clearchat")
      expect(msg.raw_tags["ban-duration"]).to eq("600")
    end

    it "resolves stream_id from channel_login" do
      channel = create(:channel, login: "testchannel")
      stream = create(:stream, channel: channel, ended_at: nil)

      push_message(sample_message)
      worker.perform

      msg = ChatMessage.last
      expect(msg.stream_id).to eq(stream.id)
    end

    it "handles messages without active stream (stream_id = nil)" do
      push_message(sample_message(channel_login: "nochannel"))
      worker.perform

      msg = ChatMessage.last
      expect(msg.stream_id).to be_nil
    end

    # TASK-251.5 CR nit-1: drained batch must not be lost on an unexpected insert failure
    it "re-queues the drained batch and re-raises on an unexpected insert failure" do
      push_message(sample_message)
      allow(ChatMessage).to receive(:insert_all).and_raise(ActiveRecord::ConnectionNotEstablished)

      expect { worker.perform }.to raise_error(ActiveRecord::ConnectionNotEstablished)
      expect(Redis.new(url: redis_url).llen(redis_key)).to eq(1) # restored, not lost
    end
  end

  # TASK-251.14b: best-effort dual-write to ClickHouse. Postgres stays source of truth.
  describe "ClickHouse dual-write" do
    let(:ch_client) { instance_double(Clickhouse::Client) }
    let(:captured) { [] }

    before do
      allow(Clickhouse).to receive(:client).and_return(ch_client)
      allow(ch_client).to receive(:insert) { |_table, rows, **| captured.replace(rows) }
      allow(Flipper).to receive(:enabled?).and_call_original
    end

    context "when :chat_writes_clickhouse is OFF (default)" do
      before { allow(Flipper).to receive(:enabled?).with(:chat_writes_clickhouse).and_return(false) }

      it "writes only to Postgres, never touches ClickHouse" do
        push_message(sample_message)
        expect { worker.perform }.to change(ChatMessage, :count).by(1)
        expect(Clickhouse).not_to have_received(:client)
      end
    end

    context "when :chat_writes_clickhouse is ON" do
      before { allow(Flipper).to receive(:enabled?).with(:chat_writes_clickhouse).and_return(true) }

      it "mirrors the batch into ClickHouse alongside Postgres" do
        push_message(sample_message)
        push_message(sample_message(username: "user2"))

        expect { worker.perform }.to change(ChatMessage, :count).by(2)
        expect(ch_client).to have_received(:insert).with("chat_messages", anything, best_effort: true)
        expect(captured.size).to eq(2)
        expect(captured.map { |r| r[:channel_login] }).to all(eq("testchannel"))
      end

      it "mirrors only the rows Postgres actually persisted (fallback skips invalid → no CH-superset)" do
        push_message(sample_message(username: "good"))
        push_message(sample_message(username: "bad"))
        # Force the per-record fallback, then make only the "bad" record fail PG validation.
        allow(ChatMessage).to receive(:insert_all).and_raise(ActiveRecord::StatementInvalid, "boom")
        allow(ChatMessage).to receive(:create!).and_call_original
        allow(ChatMessage).to receive(:create!).with(hash_including(username: "bad"))
                                               .and_raise(ActiveRecord::RecordInvalid.new(ChatMessage.new))

        worker.perform

        expect(captured.map { |r| r[:username] }).to eq([ "good" ])
      end

      it "maps each row to the ClickHouse shape (bool→UInt8, raw_tags→JSON, ts→DateTime64 text, nil→\"\")" do
        push_message(sample_message(vip: true, is_first_msg: false, display_name: nil,
                                    raw_tags: { "a" => "b" }, timestamp: "2026-05-27T12:00:00Z"))
        worker.perform

        row = captured.first
        expect(row[:vip]).to eq(1)
        expect(row[:is_first_msg]).to eq(0)
        expect(row[:display_name]).to eq("")
        expect(row[:raw_tags]).to eq('{"a":"b"}')
        expect(row[:timestamp]).to match(/\A\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3}\z/)
      end

      it "is best-effort: a ClickHouse failure neither raises nor re-queues (Postgres is source of truth)" do
        allow(ch_client).to receive(:insert).and_raise(Clickhouse::QueryError, "boom")
        push_message(sample_message)

        expect { worker.perform }.to change(ChatMessage, :count).by(1) # PG ok; CH error swallowed
        expect(Redis.new(url: redis_url).llen(redis_key)).to eq(0)     # batch consumed, NOT requeued
      end
    end
  end
end
