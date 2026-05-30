# frozen_string_literal: true

require "rails_helper"

RSpec.describe Clickhouse::ChatBackfill do
  let(:t0) { Time.utc(2026, 5, 28, 3, 29, 10) }
  let(:redis_url) { "redis://localhost:6379/1" }
  let(:redis) { Redis.new(url: redis_url) }
  let(:ch_client) { instance_double(Clickhouse::Client) }
  let(:logger) { Logger.new(IO::NULL) }

  before do
    # Per-example isolated Redis namespace via a unique prefix bound to the example id, so parallel
    # specs / leftover keys never leak across runs. The service hard-codes REDIS_PREFIX, but Redis is
    # cleared per example to keep state deterministic.
    skip "Redis not available" unless redis.ping == "PONG"
    %w[t0 cursor_id rows_processed status last_error].each do |k|
      redis.del("#{described_class::REDIS_PREFIX}:#{k}")
    end
    allow(ENV).to receive(:fetch).and_call_original
    allow(ENV).to receive(:fetch).with("REDIS_URL", anything).and_return(redis_url)
    allow(Flipper).to receive(:enabled?).and_call_original
    allow(ch_client).to receive(:insert)
  rescue Redis::CannotConnectError
    skip "Redis not reachable"
  end

  def call(**opts)
    described_class.call(t0: t0, redis: redis, client: ch_client, logger: logger,
                         batch_size: 2, sleep_seconds: 0, **opts)
  end

  describe "happy path (mocked CH)" do
    before { allow(Flipper).to receive(:enabled?).with(:chat_backfill_running).and_return(true) }

    it "returns status=done with no rows when Postgres is empty (pre-T0)" do
      result = call
      expect(result.status).to eq("done")
      expect(result.rows_processed).to eq(0)
      expect(result.batches).to eq(0)
      expect(ch_client).not_to have_received(:insert)
    end

    it "batches pre-T0 rows in id ASC order, advances Redis cursor, calls CH#insert per batch" do
      channel = create(:channel)
      stream = create(:stream, channel: channel, ended_at: nil)
      # 5 pre-T0 rows + 1 post-T0 row (must be skipped).
      pre = Array.new(5) do |i|
        create(:chat_message, stream: stream, channel_login: channel.login,
                              msg_type: "privmsg", username: "u#{i}", timestamp: t0 - (i + 1).minutes)
      end
      _post = create(:chat_message, stream: stream, channel_login: channel.login,
                                    msg_type: "privmsg", username: "future", timestamp: t0 + 1.minute)

      result = call

      expect(result.status).to eq("done")
      expect(result.rows_processed).to eq(5)
      expect(result.batches).to eq(3) # 2 + 2 + 1
      expect(ch_client).to have_received(:insert).exactly(3).times
      # Cursor lands on the highest-id pre-T0 row.
      expect(redis.get("#{described_class::REDIS_PREFIX}:cursor_id")).to eq(pre.map(&:id).max)
      expect(redis.get("#{described_class::REDIS_PREFIX}:status")).to eq("done")
    end

    it "maps each row via Clickhouse::ChatRow (single source of truth with the live mirror)" do
      channel = create(:channel)
      stream = create(:stream, channel: channel, ended_at: nil)
      create(:chat_message, stream: stream, channel_login: channel.login,
                            msg_type: "privmsg", username: "alice", timestamp: t0 - 5.minutes,
                            raw_tags: { "k" => "v" })

      received = nil
      allow(ch_client).to receive(:insert) { |_table, rows| received = rows }

      call

      expect(received.size).to eq(1)
      row = received.first
      expect(row[:username]).to eq("alice")
      expect(row[:raw_tags]).to eq('{"k":"v"}')
      expect(row[:timestamp]).to match(/\A\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3}\z/)
    end
  end

  describe "kill-switch" do
    it "exits cleanly with status=paused (cursor preserved) when the flag flips OFF mid-run" do
      channel = create(:channel)
      stream = create(:stream, channel: channel, ended_at: nil)
      pre = Array.new(4) do |i|
        create(:chat_message, stream: stream, channel_login: channel.login,
                              msg_type: "privmsg", username: "u#{i}", timestamp: t0 - (i + 1).minutes)
      end
      sorted_ids = pre.map(&:id).sort
      # First check returns true (run one batch), second check returns false (paused).
      allow(Flipper).to receive(:enabled?).with(:chat_backfill_running).and_return(true, false)

      result = call
      expect(result.status).to eq("paused")
      expect(result.rows_processed).to eq(2)        # exactly one batch processed
      expect(result.batches).to eq(1)
      expect(redis.get("#{described_class::REDIS_PREFIX}:cursor_id")).to eq(sorted_ids[1]) # 2nd-lowest id
    end

    it "aborts immediately if the flag was never enabled (no work done)" do
      create(:chat_message, channel_login: "x", msg_type: "privmsg",
                            username: "u", timestamp: t0 - 1.minute)
      allow(Flipper).to receive(:enabled?).with(:chat_backfill_running).and_return(false)

      result = call
      expect(result.status).to eq("paused")
      expect(result.rows_processed).to eq(0)
      expect(ch_client).not_to have_received(:insert)
    end
  end

  describe "resumability" do
    before { allow(Flipper).to receive(:enabled?).with(:chat_backfill_running).and_return(true) }

    it "starts from the persisted Redis cursor, skipping already-processed rows" do
      channel = create(:channel)
      stream = create(:stream, channel: channel, ended_at: nil)
      rows = Array.new(4) do |i|
        create(:chat_message, stream: stream, channel_login: channel.login,
                              msg_type: "privmsg", username: "u#{i}", timestamp: t0 - (i + 1).minutes)
      end
      sorted_ids = rows.map(&:id).sort
      # Pretend a previous run processed rows up to the 2nd-lowest id.
      redis.set("#{described_class::REDIS_PREFIX}:cursor_id", sorted_ids[1])
      redis.set("#{described_class::REDIS_PREFIX}:rows_processed", "2")

      result = call

      expect(result.rows_processed).to eq(4) # 2 prior + 2 new this run
      expect(redis.get("#{described_class::REDIS_PREFIX}:cursor_id")).to eq(sorted_ids.last)
    end
  end

  describe "failure path" do
    before { allow(Flipper).to receive(:enabled?).with(:chat_backfill_running).and_return(true) }

    it "leaves the cursor untouched on CH error so a re-run resumes the same batch (status=failed)" do
      channel = create(:channel)
      stream = create(:stream, channel: channel, ended_at: nil)
      create(:chat_message, stream: stream, channel_login: channel.login,
                            msg_type: "privmsg", username: "u", timestamp: t0 - 1.minute)
      allow(ch_client).to receive(:insert).and_raise(Clickhouse::QueryError, "boom")

      result = call

      expect(result.status).to eq("failed")
      expect(redis.get("#{described_class::REDIS_PREFIX}:status")).to eq("failed")
      expect(redis.get("#{described_class::REDIS_PREFIX}:last_error")).to include("Clickhouse::QueryError")
      expect(redis.get("#{described_class::REDIS_PREFIX}:cursor_id")).to be_nil
    end
  end

  # TASK-251.58: #tick is the single-batch operation extracted from the original #call loop.
  # Used by both the legacy operator-driven blocking loop (`rake clickhouse:backfill_chat`) AND
  # the new Sidekiq-cron worker (Clickhouse::ChatBackfillCycleWorker). Direct unit coverage of
  # #tick is needed because the worker exercises it in a timeboxed loop, not via #call.
  describe "#tick" do
    let(:instance) do
      described_class.new(t0: t0, redis: redis, client: ch_client, logger: logger,
                          batch_size: 2, sleep_seconds: 0)
    end

    it "returns :paused without touching CH when :chat_backfill_running flag is OFF" do
      allow(Flipper).to receive(:enabled?).with(:chat_backfill_running).and_return(false)
      create(:chat_message, channel_login: "x", msg_type: "privmsg",
                            username: "u", timestamp: t0 - 1.minute)

      result = instance.tick

      expect(result[:status]).to eq(:paused)
      expect(ch_client).not_to have_received(:insert)
    end

    it "returns :done and sets Redis status=done when no pre-T0 rows remain" do
      allow(Flipper).to receive(:enabled?).with(:chat_backfill_running).and_return(true)

      result = instance.tick

      expect(result[:status]).to eq(:done)
      expect(redis.get("#{described_class::REDIS_PREFIX}:status")).to eq("done")
    end

    it "returns :ok, advances Redis cursor + rows_processed, sets status=running on successful batch" do
      allow(Flipper).to receive(:enabled?).with(:chat_backfill_running).and_return(true)
      channel = create(:channel)
      stream = create(:stream, channel: channel, ended_at: nil)
      pre = Array.new(3) do |i|
        create(:chat_message, stream: stream, channel_login: channel.login,
                              msg_type: "privmsg", username: "u#{i}", timestamp: t0 - (i + 1).minutes)
      end
      sorted_ids = pre.map(&:id).sort

      result = instance.tick

      expect(result[:status]).to eq(:ok)
      expect(result[:batch_size]).to eq(2)
      expect(result[:rows_processed]).to eq(2)
      expect(result[:cursor]).to eq(sorted_ids[1])
      expect(redis.get("#{described_class::REDIS_PREFIX}:cursor_id")).to eq(sorted_ids[1])
      expect(redis.get("#{described_class::REDIS_PREFIX}:status")).to eq("running")
      expect(ch_client).to have_received(:insert).once
    end

    it "returns :failed and sets Redis status=failed without advancing cursor on CH error" do
      allow(Flipper).to receive(:enabled?).with(:chat_backfill_running).and_return(true)
      create(:chat_message, channel_login: "x", msg_type: "privmsg",
                            username: "u", timestamp: t0 - 1.minute)
      allow(ch_client).to receive(:insert).and_raise(Clickhouse::QueryError, "boom")

      result = instance.tick

      expect(result[:status]).to eq(:failed)
      expect(result[:last_error]).to include("Clickhouse::QueryError")
      expect(redis.get("#{described_class::REDIS_PREFIX}:status")).to eq("failed")
      # Cursor was never set — the failure short-circuits before the Redis cursor write.
      expect(redis.get("#{described_class::REDIS_PREFIX}:cursor_id")).to be_nil
    end

    it "is idempotent — successive ticks from the same cursor produce deterministic forward progress" do
      allow(Flipper).to receive(:enabled?).with(:chat_backfill_running).and_return(true)
      channel = create(:channel)
      stream = create(:stream, channel: channel, ended_at: nil)
      pre = Array.new(4) do |i|
        create(:chat_message, stream: stream, channel_login: channel.login,
                              msg_type: "privmsg", username: "u#{i}", timestamp: t0 - (i + 1).minutes)
      end
      sorted_ids = pre.map(&:id).sort

      r1 = instance.tick # rows 1-2
      r2 = instance.tick # rows 3-4
      r3 = instance.tick # done

      expect([ r1[:status], r2[:status], r3[:status] ]).to eq([ :ok, :ok, :done ])
      expect(r2[:cursor]).to eq(sorted_ids.last)
      expect(r2[:rows_processed]).to eq(4)
      expect(ch_client).to have_received(:insert).exactly(2).times
    end
  end

  describe "integration (real ClickHouse)", :clickhouse do
    let(:real_client) { Clickhouse.client }
    let(:channel) { create(:channel) }
    let(:stream) { create(:stream, channel: channel, ended_at: nil) }
    let(:stream_id) { stream.id }

    before do
      skip "ClickHouse not reachable" unless real_client.ping
      allow(Flipper).to receive(:enabled?).with(:chat_backfill_running).and_return(true)
    end
    # No after-cleanup: each example uses a unique stream_id (factory-generated UUID), so the rows
    # this spec inserts don't interfere with any other spec's queries (they all filter by stream_id).
    # The CI ClickHouse service is ephemeral; local runs skip the example entirely.

    it "round-trips Postgres rows into real ClickHouse with the exact rowset and order" do
      pre = Array.new(3) do |i|
        create(:chat_message, stream: stream, channel_login: channel.login,
                              msg_type: "privmsg", username: "user#{i}", timestamp: t0 - (3 - i).minutes,
                              raw_tags: { "n" => i })
      end
      create(:chat_message, stream: stream, channel_login: channel.login,
                            msg_type: "privmsg", username: "future", timestamp: t0 + 1.minute)

      result = described_class.call(t0: t0, redis: redis, client: real_client, logger: logger,
                                    batch_size: 10, sleep_seconds: 0)

      expect(result.status).to eq("done")
      expect(result.rows_processed).to eq(3)

      ch_rows = real_client.select(
        "SELECT username, raw_tags FROM chat_messages WHERE stream_id = '#{stream_id}' ORDER BY username"
      )
      expect(ch_rows.map { |r| r["username"] }).to eq(%w[user0 user1 user2])
      expect(ch_rows.map { |r| JSON.parse(r["raw_tags"])["n"] }).to eq([ 0, 1, 2 ])
      _ = pre # silence unused
    end
  end
end
