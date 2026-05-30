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

  before do
    skip "Redis not reachable" unless redis.ping == "PONG"
    %w[t0 cursor_id rows_processed status last_error].each { |k| redis.del("#{prefix}:#{k}") }
    allow(ENV).to receive(:fetch).and_call_original
    allow(ENV).to receive(:fetch).with("REDIS_URL", anything).and_return(redis_url)
    allow(Flipper).to receive(:enabled?).and_call_original
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

    it "is a no-op when T0 is unset in Redis (flag ON but operator hasn't seeded T0)" do
      allow(Flipper).to receive(:enabled?).with(:chat_backfill_running).and_return(true)
      # T0 not set → worker logs warn and returns without invoking the service.
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

  describe "#perform — tick loop" do
    let(:backfill) { instance_double(Clickhouse::ChatBackfill) }

    before do
      allow(Flipper).to receive(:enabled?).with(:chat_backfill_running).and_return(true)
      redis.set("#{prefix}:t0", t0_iso)
      allow(Clickhouse::ChatBackfill).to receive(:new).and_return(backfill)
      allow(described_class.new).to receive(:sleep) # spec speed; instance-method stub via allow_any_instance_of
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
      # 3 successful ticks, then done.
      allow(backfill).to receive(:tick).and_return(ok_result, ok_result, ok_result, done_result)

      described_class.new.perform

      expect(backfill).to have_received(:tick).exactly(4).times
    end

    it "respects MAX_RUNTIME_SECONDS deadline (timeboxed; cron re-fires next minute)" do
      # Stub Time.current to advance past the deadline after a few ticks.
      base = Time.current
      times = [ base, base + 10, base + 20, base + 30, base + described_class::MAX_RUNTIME_SECONDS + 1 ]
      allow(Time).to receive(:current).and_return(*times)
      allow(backfill).to receive(:tick).and_return({ status: :ok, cursor: "x", batch_size: 5_000, rows_processed: 5_000 })

      expect(Rails.logger).to receive(:info).with(/ran .* ticks within #{described_class::MAX_RUNTIME_SECONDS}s budget/)

      described_class.new.perform
    end
  end
end
