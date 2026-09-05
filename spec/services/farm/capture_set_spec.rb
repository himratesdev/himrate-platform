# frozen_string_literal: true

require "rails_helper"

RSpec.describe Farm::CaptureSet do
  let(:redis_url) { "redis://localhost:6379/1" }
  let(:redis) { Redis.new(url: redis_url) }
  let(:set) { described_class.new(redis: redis) }

  before do
    redis.del(described_class::SET_KEY)
  rescue Redis::CannotConnectError
    skip "Redis not available"
  end

  after { redis.del(described_class::SET_KEY) rescue nil }

  def entry(login)
    JSON.parse(redis.hget(described_class::SET_KEY, login))
  end

  describe "#sync" do
    it "joins newcomers, stamps game_id/first_seen, and publishes a join command" do
      expect(redis).to receive(:publish).with(described_class::COMMANDS_CHANNEL, { action: "join", channel_login: "a" }.to_json)

      stats = set.sync(live: { "a" => "493057" }, complete_game_ids: Set["493057"])

      expect(stats.joined).to eq(1)
      expect(entry("a")).to include("game_id" => "493057", "misses" => 0)
      expect(entry("a")["first_seen_at"]).to be_present
    end

    it "never joins channels held by the bot-detection IRC (excluded) and parts them if present" do
      set.sync(live: { "held" => "1" }, complete_game_ids: Set["1"])
      allow(redis).to receive(:publish)

      stats = set.sync(live: { "held" => "1" }, complete_game_ids: Set["1"], excluded: Set["held"])

      expect(stats.joined).to eq(0)
      expect(stats.parted).to eq(1)
      expect(set.logins).to be_empty
      expect(redis).to have_received(:publish).with(described_class::COMMANDS_CHANNEL, { action: "part", channel_login: "held" }.to_json)
    end

    it "debounces: parts only after OFFLINE_MISS_THRESHOLD consecutive misses" do
      allow(redis).to receive(:publish)
      set.sync(live: { "a" => "1" }, complete_game_ids: Set["1"])

      (described_class::OFFLINE_MISS_THRESHOLD - 1).times do |i|
        stats = set.sync(live: {}, complete_game_ids: Set["1"])
        expect(stats.parted).to eq(0)
        expect(entry("a")["misses"]).to eq(i + 1)
      end

      stats = set.sync(live: {}, complete_game_ids: Set["1"])
      expect(stats.parted).to eq(1)
      expect(set.logins).to be_empty
      expect(redis).to have_received(:publish).with(described_class::COMMANDS_CHANNEL, { action: "part", channel_login: "a" }.to_json)
    end

    it "a reappearance resets the miss counter" do
      allow(redis).to receive(:publish)
      set.sync(live: { "a" => "1" }, complete_game_ids: Set["1"])
      set.sync(live: {}, complete_game_ids: Set["1"])
      expect(entry("a")["misses"]).to eq(1)

      stats = set.sync(live: { "a" => "1" }, complete_game_ids: Set["1"])

      expect(stats.kept).to eq(1)
      expect(entry("a")["misses"]).to eq(0)
    end

    it "treats a category whose paging failed as 'no information': no misses, no parts (BUG-251.19 semantics)" do
      allow(redis).to receive(:publish)
      set.sync(live: { "a" => "1", "b" => "2" }, complete_game_ids: Set["1", "2"])

      stats = set.sync(live: { "b" => "2" }, complete_game_ids: Set["2"]) # category 1 failed this cycle

      expect(stats.skipped_incomplete).to eq(1)
      expect(stats.parted).to eq(0)
      expect(entry("a")["misses"]).to eq(0)
    end

    it "updates game_id when a channel moves between farmed categories" do
      allow(redis).to receive(:publish)
      set.sync(live: { "a" => "1" }, complete_game_ids: Set["1", "2"])

      set.sync(live: { "a" => "2" }, complete_game_ids: Set["1", "2"])

      expect(entry("a")["game_id"]).to eq("2")
      expect(set.game_ids).to eq("a" => "2")
    end
  end
end
