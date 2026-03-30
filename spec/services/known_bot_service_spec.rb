# frozen_string_literal: true

require "rails_helper"

RSpec.describe KnownBotService do
  let(:service) { described_class.new }

  before do
    KnownBotList.delete_all

    allow(ENV).to receive(:fetch).and_call_original
    allow(ENV).to receive(:fetch).with("REDIS_URL", anything).and_return("redis://localhost:6379/1")

    # Clean Redis keys
    r = Redis.new(url: "redis://localhost:6379/1")
    %w[all commanderroot twitchinsights twitchbots_info streamscharts truevio test_support].each do |suffix|
      r.del("known_bots:#{suffix}")
      r.del("known_bots:#{suffix}:new")
    end
  rescue Redis::CannotConnectError
    skip "Redis not available"
  end

  describe "#bot?" do
    before do
      # Add test data to Redis (using SET since local Redis may not have Bloom)
      r = Redis.new(url: "redis://localhost:6379/1")
      r.sadd("known_bots:all", "known_bot_user")
      r.sadd("known_bots:commanderroot", "known_bot_user")
      r.sadd("known_bots:twitchinsights", "known_bot_user")
      r.sadd("known_bots:all", "single_source_bot")
      r.sadd("known_bots:commanderroot", "single_source_bot")
    end

    # TC-001: known bot returns true
    it "returns true with confidence for known bot" do
      result = service.bot?("known_bot_user")
      expect(result[:bot]).to be true
      expect(result[:confidence]).to eq(0.95) # 2 sources
      expect(result[:sources]).to include("commanderroot", "twitchinsights")
    end

    # TC-002: unknown returns false
    it "returns false for unknown username" do
      result = service.bot?("real_human_user")
      expect(result[:bot]).to be false
      expect(result[:confidence]).to eq(0.0)
    end

    # TC-003: 2+ sources → 0.95
    it "returns 0.95 confidence for 2+ sources" do
      result = service.bot?("known_bot_user")
      expect(result[:confidence]).to eq(0.95)
    end

    # TC-004: 1 source → 0.75
    it "returns 0.75 confidence for single source" do
      result = service.bot?("single_source_bot")
      expect(result[:confidence]).to eq(0.75)
    end

    # TC-013: Redis down → graceful false
    it "returns false when Redis unavailable" do
      allow(service).to receive(:redis).and_raise(Redis::CannotConnectError)
      # Should not raise, should return safe default
      result = service.bot?("any_user")
      expect(result[:bot]).to be false
    end
  end

  describe "#check_batch" do
    before do
      r = Redis.new(url: "redis://localhost:6379/1")
      r.sadd("known_bots:all", "bot1")
      r.sadd("known_bots:commanderroot", "bot1")
      r.sadd("known_bots:all", "bot2")
      r.sadd("known_bots:twitchinsights", "bot2")
    end

    # TC-005: batch returns Hash
    it "returns hash with results for batch" do
      results = service.check_batch(%w[bot1 bot2 human1])

      expect(results["bot1"][:bot]).to be true
      expect(results["bot2"][:bot]).to be true
      expect(results["human1"][:bot]).to be false
      expect(results.size).to eq(3)
    end
  end

  describe "#add_bot" do
    # TC-011: adds to DB + filter
    it "adds bot to known_bot_lists and Bloom Filter" do
      result = service.add_bot("new_bot", "truevio", 0.95, category: "view_bot")

      expect(result).to eq(:ok)
      expect(KnownBotList.find_by(username: "new_bot", source: "truevio")).to be_present
      expect(service.bot?("new_bot")[:bot]).to be true
    end

    # TC-012: duplicate → idempotent
    it "returns :exists for duplicate" do
      service.add_bot("dup_bot", "truevio", 0.95)
      result = service.add_bot("dup_bot", "truevio", 0.95)
      expect(result).to eq(:exists)
    end

    # TC-018: bot_category = service_bot
    it "stores bot_category correctly" do
      service.add_bot("nightbot", "twitchbots_info", 0.75, category: "service_bot")
      record = KnownBotList.find_by(username: "nightbot")
      expect(record.bot_category).to eq("service_bot")
    end

    # TC-019: bot_category = view_bot
    it "stores view_bot category" do
      service.add_bot("viewbot123", "commanderroot", 0.75, category: "view_bot")
      record = KnownBotList.find_by(username: "viewbot123")
      expect(record.bot_category).to eq("view_bot")
    end

    # TC-020: twitch_native confidence 1.0
    it "stores twitch_native with confidence 1.0" do
      service.add_bot("twitch_chatbot", "truevio", 1.0, category: "service_bot")
      record = KnownBotList.find_by(username: "twitch_chatbot")
      expect(record.confidence.to_f).to eq(1.0)
    end
  end

  describe "#touch_bot" do
    # TC-021: updates last_seen_at
    it "updates last_seen_at" do
      service.add_bot("seen_bot", "commanderroot", 0.75)

      expect { service.touch_bot("seen_bot") }
        .to change { KnownBotList.find_by(username: "seen_bot").last_seen_at }
        .from(nil)
    end
  end

  describe "#rebuild_filters" do
    # TC-010: rebuild + atomic swap
    it "rebuilds all Bloom Filters" do
      source_data = {
        "commanderroot" => %w[bot1 bot2 bot3],
        "twitchinsights" => %w[bot1 bot4]
      }

      total = service.rebuild_filters(source_data)

      expect(total).to eq(4) # bot1 bot2 bot3 bot4
      expect(service.bot?("bot1")[:bot]).to be true
      expect(service.bot?("bot1")[:sources]).to include("commanderroot", "twitchinsights")
      expect(service.bot?("bot3")[:bot]).to be true
      expect(service.bot?("unknown")[:bot]).to be false
    end
  end

  describe "#stats" do
    it "returns statistics" do
      service.add_bot("bot1", "commanderroot", 0.75, category: "view_bot")
      service.add_bot("bot2", "twitchbots_info", 0.75, category: "service_bot")

      stats = service.stats
      expect(stats[:total_db]).to eq(2)
      expect(stats[:per_source]).to include("commanderroot" => 1)
      expect(stats[:per_category]).to include("view_bot" => 1, "service_bot" => 1)
    end

    # TC-014: Explicit bloom_support check
    it "reports bloom_support status" do
      stats = service.stats
      expect(stats).to have_key(:bloom_support)
      # Local test Redis likely has no Bloom → false
      expect(stats[:bloom_support]).to be(true).or be(false)
    end
  end
end
