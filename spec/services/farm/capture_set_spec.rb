# frozen_string_literal: true

require "rails_helper"

RSpec.describe Farm::CaptureSet do
  let(:redis_url) { "redis://localhost:6379/1" }
  let(:redis) { Redis.new(url: redis_url) }
  let(:set) { described_class.new(redis: redis) }
  let(:commands) { [] }

  before do
    redis.del(described_class::SET_KEY)
    # Capture pub/sub commands without a subscriber: publish is called on the pipeline (pipelined
    # writes), so intercept at the CaptureSet level.
    allow(set).to receive(:publish) { |action, login, _conn| commands << [ action, login ] }
  rescue Redis::CannotConnectError
    skip "Redis not available"
  end

  after { redis.del(described_class::SET_KEY) rescue nil }

  def entry(login)
    JSON.parse(redis.hget(described_class::SET_KEY, login))
  end

  def sync(live:, configured: nil, complete: nil, excluded: Set.new)
    configured ||= Set.new(live.values)
    complete ||= configured
    set.sync(live: live, configured_game_ids: configured, complete_game_ids: complete, excluded: excluded)
  end

  describe "#sync" do
    it "joins newcomers, stamps game_id/first_seen, and publishes a join command" do
      stats = sync(live: { "a" => "493057" })

      expect(stats.joined).to eq(1)
      expect(entry("a")).to include("game_id" => "493057", "misses" => 0)
      expect(entry("a")["first_seen_at"]).to be_present
      expect(commands).to eq([ [ "join", "a" ] ])
    end

    it "never joins channels held by the bot-detection IRC (excluded) and parts them if present" do
      sync(live: { "held" => "1" })
      commands.clear

      stats = sync(live: { "held" => "1" }, excluded: Set["held"])

      expect(stats.joined).to eq(0)
      expect(stats.parted).to eq(1)
      expect(set.logins).to be_empty
      expect(commands).to eq([ [ "part", "held" ] ])
    end

    it "parts an excluded channel even when its category paged incompletely this cycle (N1)" do
      sync(live: { "held" => "1" })
      commands.clear

      stats = sync(live: {}, configured: Set["1"], complete: Set.new, excluded: Set["held"])

      expect(stats.parted).to eq(1)
      expect(commands).to eq([ [ "part", "held" ] ])
    end

    it "debounces: parts only after OFFLINE_MISS_THRESHOLD consecutive misses" do
      sync(live: { "a" => "1" })
      commands.clear

      (described_class::OFFLINE_MISS_THRESHOLD - 1).times do |i|
        stats = sync(live: {}, configured: Set["1"])
        expect(stats.parted).to eq(0)
        expect(entry("a")["misses"]).to eq(i + 1)
      end

      stats = sync(live: {}, configured: Set["1"])
      expect(stats.parted).to eq(1)
      expect(set.logins).to be_empty
      expect(commands).to eq([ [ "part", "a" ] ])
    end

    it "a reappearance resets the miss counter" do
      sync(live: { "a" => "1" })
      sync(live: {}, configured: Set["1"])
      expect(entry("a")["misses"]).to eq(1)

      stats = sync(live: { "a" => "1" })

      expect(stats.kept).to eq(1)
      expect(entry("a")["misses"]).to eq(0)
    end

    it "treats a category whose paging failed as 'no information': no misses, no parts (BUG-251.19 semantics)" do
      sync(live: { "a" => "1", "b" => "2" })

      stats = sync(live: { "b" => "2" }, configured: Set["1", "2"], complete: Set["2"]) # category 1 failed this cycle

      expect(stats.skipped_incomplete).to eq(1)
      expect(stats.parted).to eq(0)
      expect(entry("a")["misses"]).to eq(0)
    end

    it "parts every channel of a category that was disabled/removed in ONE cycle, no debounce (M1)" do
      sync(live: { "a" => "1", "b" => "1", "c" => "2" })
      commands.clear

      stats = sync(live: { "c" => "2" }, configured: Set["2"], complete: Set["2"]) # category 1 disabled

      expect(stats.parted).to eq(2)
      expect(set.logins).to eq([ "c" ])
      expect(commands).to contain_exactly([ "part", "a" ], [ "part", "b" ])
    end

    it "releases everything when no category is configured any more (M1: disable-all must PART)" do
      sync(live: { "a" => "1", "b" => "2" })
      commands.clear

      stats = sync(live: {}, configured: Set.new, complete: Set.new)

      expect(stats.parted).to eq(2)
      expect(set.logins).to be_empty
    end

    it "updates game_id when a channel moves between farmed categories" do
      sync(live: { "a" => "1" }, configured: Set["1", "2"])

      sync(live: { "a" => "2" }, configured: Set["1", "2"])

      expect(entry("a")["game_id"]).to eq("2")
      expect(set.game_ids).to eq("a" => "2")
    end

    it "writes all mutations in a single pipeline (N3)" do
      expect(redis).to receive(:pipelined).once.and_call_original

      sync(live: { "a" => "1", "b" => "1", "c" => "1" })

      expect(set.logins).to contain_exactly("a", "b", "c")
    end
  end
end
