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
  end
end
