# frozen_string_literal: true

require "rails_helper"

# TASK-251.58: Sidekiq cron-driven backfill cycle replacement for the previous detached-rake
# pattern that died on every Kamal deploy (container swap). The worker timeboxes a #tick loop
# against Clickhouse::ChatBackfill so the cycle resumes natively post-deploy.
RSpec.describe Clickhouse::ChatBackfillCycleWorker do
  let(:redis_url) { "redis://localhost:6379/1" }
  let(:redis) { Redis.new(url: redis_url) }
  let(:t0) { Time.utc(2026, 5, 28, 3, 32, 0) }
  let(:t0_iso) { t0.iso8601 }
  let(:prefix) { Clickhouse::ChatBackfill::REDIS_PREFIX }
  let(:lock_key) { described_class::LOCK_KEY }

  before do
    skip "Redis not reachable" unless redis.ping == "PONG"
    %w[t0 cursor_id rows_processed status last_error cycle_lock].each { |k| redis.del("#{prefix}:#{k}") }
    allow(ENV).to receive(:fetch).and_call_original
    allow(ENV).to receive(:fetch).with("REDIS_URL", anything).and_return(redis_url)
    allow(Flipper).to receive(:enabled?).and_call_original
    # Sidekiq.redis pool may not be configured in unit-spec context — stub it to use our test Redis.
    allow(Sidekiq).to receive(:redis).and_yield(redis)
  rescue Redis::CannotConnectError
    skip "Redis not reachable"
  end

  describe "#perform — kill-switch + preconditions" do
    it "is a no-op when :chat_backfill_running flag is OFF (does not even read T0)" do
      allow(Flipper).to receive(:enabled?).with(:chat_backfill_running).and_return(false)
      redis.set("#{prefix}:t0", t0_iso)
      expect(Clickhouse::ChatBackfill).not_to receive(:new)

      described_class.new.perform
    end

    # CR iter1 S1: short-circuit on Redis status=done so the cron stays scheduled (for future
    # re-backfills) but does not spam logs every minute once terminally finished.
    it "is a no-op when Redis status=done (terminal — operator clears key to re-arm)" do
      allow(Flipper).to receive(:enabled?).with(:chat_backfill_running).and_return(true)
      redis.set("#{prefix}:t0", t0_iso)
      redis.set("#{prefix}:status", "done")
      expect(Clickhouse::ChatBackfill).not_to receive(:new)

      described_class.new.perform
    end

    it "is a no-op when T0 is unset in Redis (flag ON but operator hasn't seeded T0)" do
      allow(Flipper).to receive(:enabled?).with(:chat_backfill_running).and_return(true)
      expect(Clickhouse::ChatBackfill).not_to receive(:new)
      expect(Rails.logger).to receive(:warn).with(/T0 not set in Redis/)

      described_class.new.perform
    end

    it "swallows an invalid T0 (parse error) without raising, logs error" do
      allow(Flipper).to receive(:enabled?).with(:chat_backfill_running).and_return(true)
      redis.set("#{prefix}:t0", "this-is-not-iso8601")
      expect(Rails.logger).to receive(:error).with(/T0 parse failed/)

      expect { described_class.new.perform }.not_to raise_error
    end
  end

  # CR iter1 M1: cross-process overlap lock. Two concurrent ticks would corrupt the backfill
  # (same cursor → same PG batch → double insert into no-dedup CH MergeTree).
  describe "#perform — concurrent-tick overlap lock" do
    let(:backfill) { instance_double(Clickhouse::ChatBackfill) }

    before do
      allow(Flipper).to receive(:enabled?).with(:chat_backfill_running).and_return(true)
      redis.set("#{prefix}:t0", t0_iso)
      allow(Clickhouse::ChatBackfill).to receive(:new).and_return(backfill)
      allow(backfill).to receive(:tick).and_return({ status: :done, cursor: "x", rows_processed: 0 })
    end

    it "acquires the SETNX lock and runs when the lock is free" do
      described_class.new.perform

      expect(backfill).to have_received(:tick).once
      # Lock is released in #ensure, so post-run it should be gone.
      expect(redis.get(lock_key)).to be_nil
    end

    it "skips the cycle when the lock is held by a prior tick (does NOT call #tick)" do
      # Simulate prior tick holding the lock.
      redis.set(lock_key, "other-token", nx: true, ex: described_class::LOCK_TTL_SECONDS)
      expect(Rails.logger).to receive(:info).with(/cycle lock already held/)

      described_class.new.perform

      expect(backfill).not_to have_received(:tick)
      # Lock still held by the other token (we must not steal it).
      expect(redis.get(lock_key)).to eq("other-token")
    end

    it "releases the lock in ensure even when the loop raises mid-tick" do
      allow(backfill).to receive(:tick).and_raise(StandardError, "boom")

      expect { described_class.new.perform }.to raise_error(StandardError, "boom")
      expect(redis.get(lock_key)).to be_nil
    end

    it "does NOT release a lock owned by a different token (Lua check-and-delete)" do
      # Race: our tick acquires, then for some reason another holder grabs the same key
      # (e.g. TTL expired mid-run, another worker acquired). Our release must be a no-op.
      worker = described_class.new

      allow(backfill).to receive(:tick) do
        # Mid-tick, our token gets overwritten by a different holder.
        redis.set(lock_key, "different-token")
        { status: :done, cursor: "x", rows_processed: 0 }
      end

      worker.perform

      expect(redis.get(lock_key)).to eq("different-token")
    end
  end

  describe "#perform — tick loop" do
    let(:backfill) { instance_double(Clickhouse::ChatBackfill) }

    before do
      allow(Flipper).to receive(:enabled?).with(:chat_backfill_running).and_return(true)
      redis.set("#{prefix}:t0", t0_iso)
      allow(Clickhouse::ChatBackfill).to receive(:new).and_return(backfill)
      allow_any_instance_of(described_class).to receive(:sleep)
    end

    it "exits cleanly when #tick returns :done (no more pre-T0 rows)" do
      allow(backfill).to receive(:tick).and_return({ status: :done, cursor: "abc", rows_processed: 13_600_000 })
      expect(Rails.logger).to receive(:info).with(/status=done/)

      described_class.new.perform

      expect(backfill).to have_received(:tick).once
    end

    it "exits when #tick returns :paused (kill-switch flipped mid-cycle)" do
      allow(backfill).to receive(:tick).and_return({ status: :paused, cursor: "xyz", rows_processed: 7_000_000 })
      expect(Rails.logger).to receive(:info).with(/kill-switch OFF/)

      described_class.new.perform

      expect(backfill).to have_received(:tick).once
    end

    it "exits when #tick returns :failed (logs error with cursor + last_error)" do
      allow(backfill).to receive(:tick).and_return({
        status: :failed, cursor: "abc", batch_size: 5_000, rows_processed: 100_000,
        last_error: "Clickhouse::QueryError: boom"
      })
      expect(Rails.logger).to receive(:error).with(/tick failed at cursor=abc.*boom/)

      described_class.new.perform

      expect(backfill).to have_received(:tick).once
    end

    it "loops multiple :ok ticks then stops on :done" do
      ok_result = { status: :ok, cursor: "next", batch_size: 5_000, rows_processed: 5_000 }
      done_result = { status: :done, cursor: "next", rows_processed: 13_600_000 }
      allow(backfill).to receive(:tick).and_return(ok_result, ok_result, ok_result, done_result)

      described_class.new.perform

      expect(backfill).to have_received(:tick).exactly(4).times
    end

    # CR iter1 N3: clock injection (deterministic; no global Time stub).
    it "respects MAX_RUNTIME_SECONDS deadline (timeboxed; cron re-fires next minute)" do
      base = Time.utc(2026, 5, 30, 12, 0, 0)
      # Each call to clock advances by 30s; on the 3rd call, we're past the budget.
      times = [ base, base + 30, base + described_class::MAX_RUNTIME_SECONDS + 1 ]
      worker = described_class.new
      worker.clock = -> { times.shift }
      allow(backfill).to receive(:tick).and_return({ status: :ok, cursor: "x", batch_size: 5_000, rows_processed: 5_000 })

      expect(Rails.logger).to receive(:info).with(/ran 1 ticks within #{described_class::MAX_RUNTIME_SECONDS}s budget/)

      worker.perform
    end
  end
end
