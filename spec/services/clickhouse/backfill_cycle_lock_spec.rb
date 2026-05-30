# frozen_string_literal: true

require "rails_helper"

# TASK-251.58: overlap-guard lock used by ChatBackfillCycleWorker (Sidekiq cron, sole #tick
# driver after CR iter4). Direct unit coverage pins the raw-call form (CR iter2 M1: `c.eval(...)`
# fails on RedisClient::CompatClient in prod, only `c.call("EVAL", ...)` is client-agnostic).
RSpec.describe Clickhouse::BackfillCycleLock do
  let(:redis_url) { "redis://localhost:6379/1" }
  let(:redis) { Redis.new(url: redis_url) }
  let(:key) { described_class::KEY }
  let(:token_a) { "token-a-#{SecureRandom.hex(4)}" }
  let(:token_b) { "token-b-#{SecureRandom.hex(4)}" }

  before do
    skip "Redis not reachable" unless redis.ping == "PONG"
    redis.del(key)
  rescue Redis::CannotConnectError
    skip "Redis not reachable"
  end

  describe ".acquire" do
    it "returns true and sets the key when the lock is free" do
      expect(described_class.acquire(redis, token_a)).to be(true)
      expect(redis.get(key)).to eq(token_a)
    end

    it "returns false when the key is already held (does not steal)" do
      described_class.acquire(redis, token_a)
      expect(described_class.acquire(redis, token_b)).to be(false)
      expect(redis.get(key)).to eq(token_a) # untouched
    end

    it "sets a TTL matching DEFAULT_TTL_SECONDS (within ±1s tolerance)" do
      described_class.acquire(redis, token_a)
      ttl = redis.ttl(key)
      expect(ttl).to be_between(described_class::DEFAULT_TTL_SECONDS - 1, described_class::DEFAULT_TTL_SECONDS)
    end

    it "respects a custom ttl_seconds:" do
      described_class.acquire(redis, token_a, ttl_seconds: 5)
      expect(redis.ttl(key)).to be_between(4, 5)
    end
  end

  describe ".release" do
    it "deletes the key when the token matches (Lua check-and-delete)" do
      described_class.acquire(redis, token_a)
      described_class.release(redis, token_a)
      expect(redis.get(key)).to be_nil
    end

    it "does NOT delete the key when a different token holds the lock (no steal)" do
      described_class.acquire(redis, token_a)
      described_class.release(redis, token_b)
      expect(redis.get(key)).to eq(token_a)
    end

    it "is a no-op when the lock is already released (key absent)" do
      expect { described_class.release(redis, token_a) }.not_to raise_error
      expect(redis.get(key)).to be_nil
    end
  end

  # CR iter2 M1 regression guard: both methods MUST go through the raw `c.call(...)` form so they
  # work against Sidekiq's RedisClient::CompatClient (which does NOT have `set` with kwargs nor
  # `eval` with keys:/argv: in its USED_COMMANDS, falling through to CommandBuilder which raises
  # TypeError on Array kwargs). A mock client that exposes ONLY `call` would fail the test if
  # any non-raw method were used.
  describe "client-agnostic protocol (CR iter2 M1)" do
    let(:mock_client) { instance_double("RedisClient::CompatClient") }

    it "acquire goes through c.call(\"SET\", key, token, \"NX\", \"EX\", ttl)" do
      expect(mock_client).to receive(:call).with("SET", key, token_a, "NX", "EX", 80).and_return("OK")

      expect(described_class.acquire(mock_client, token_a)).to be(true)
    end

    it "release goes through c.call(\"EVAL\", script, 1, key, token) — NOT c.eval(...)" do
      expect(mock_client).to receive(:call).with(
        "EVAL", a_string_matching(/redis\.call\('GET', KEYS\[1\]\).*KEYS\[1\]/m), 1, key, token_a
      ).and_return(1)

      described_class.release(mock_client, token_a)
    end
  end
end
