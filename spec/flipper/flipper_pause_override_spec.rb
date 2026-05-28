# frozen_string_literal: true

require "rails_helper"

# BUG-251.21: tactical pause-override for ALL_FLAGS that survives Rails boot.
#
# These specs cover the `FlipperDefaults.pause_override_active?` and
# `FlipperDefaults.pause_override_reason` module methods that the boot-time initializer
# consults BEFORE auto-enabling each ALL_FLAG. The boot-loop integration itself is
# exercised by simulating the loop with the same module methods (the real initializer
# runs once at Rails boot and cannot be re-executed mid-spec without resetting Flipper).
RSpec.describe FlipperDefaults, "pause-override" do
  let(:redis_url) { "redis://localhost:6379/1" }
  let(:redis) { Redis.new(url: redis_url) }
  let(:flag) { :signal_compute }
  let(:key) { "#{described_class::PAUSE_KEY_PREFIX}:#{flag}" }

  before do
    skip "Redis not available" unless redis.ping == "PONG"
    redis.del(key)
  rescue Redis::CannotConnectError
    skip "Redis not reachable"
  end

  after { redis.del(key) }

  describe ".pause_override_active?" do
    it "returns false when no pause key is set" do
      expect(described_class.pause_override_active?(flag, redis)).to be false
    end

    it "returns true when the pause key is set" do
      redis.set(key, "TASK-251.14 backfill")
      expect(described_class.pause_override_active?(flag, redis)).to be true
    end

    it "returns true regardless of the value (any non-empty value pauses)" do
      redis.set(key, "")
      expect(described_class.pause_override_active?(flag, redis)).to be true
    end

    it "returns false when redis instance is nil (degraded mode — fail open to auto-enable)" do
      expect(described_class.pause_override_active?(flag, nil)).to be false
    end

    it "returns false on Redis::BaseError and logs a warning (fail open)" do
      broken = instance_double(Redis)
      allow(broken).to receive(:exists?).and_raise(Redis::CannotConnectError, "boom")
      expect(Rails.logger).to receive(:warn).with(/pause-override Redis probe failed for #{flag}/)
      expect(described_class.pause_override_active?(flag, broken)).to be false
    end

    it "is per-flag isolated (signal_compute pause does not affect bot_scoring)" do
      redis.set(key, "TASK-251.14 backfill")
      expect(described_class.pause_override_active?(:signal_compute, redis)).to be true
      expect(described_class.pause_override_active?(:bot_scoring, redis)).to be false
    end
  end

  describe ".pause_override_reason" do
    it "returns nil when no pause key is set" do
      expect(described_class.pause_override_reason(flag, redis)).to be_nil
    end

    it "returns the stored reason string when set" do
      redis.set(key, "TASK-251.14 backfill")
      expect(described_class.pause_override_reason(flag, redis)).to eq("TASK-251.14 backfill")
    end

    it "returns nil when redis is nil" do
      expect(described_class.pause_override_reason(flag, nil)).to be_nil
    end

    it "returns nil on Redis::BaseError (silent fail — caller logs)" do
      broken = instance_double(Redis)
      allow(broken).to receive(:get).and_raise(Redis::CannotConnectError, "boom")
      expect(described_class.pause_override_reason(flag, broken)).to be_nil
    end
  end

  describe "PAUSE_KEY_PREFIX" do
    it "is the documented constant operators rely on in runbooks + redis-cli usage" do
      expect(described_class::PAUSE_KEY_PREFIX).to eq("flipper:pause_override")
    end
  end

  # Lifecycle integration — what the initializer ALL_FLAGS loop does, simulated with the
  # same module methods. Boot is single-shot so we re-create the situation by directly
  # invoking the same boot decision for ONE flag, with Flipper state set up by rails_helper.
  describe "boot-loop behavior (simulated)" do
    # The boot loop body, factored as a lambda so the spec exercises the exact logic.
    let(:boot_decision) do
      lambda do |target_flag, r|
        Flipper.add(target_flag)
        if described_class.pause_override_active?(target_flag, r)
          Flipper.disable(target_flag)
        else
          Flipper.enable(target_flag)
        end
      end
    end

    it "auto-enables a flag with no pause key (current behavior preserved)" do
      Flipper.disable(flag)
      boot_decision.call(flag, redis)
      expect(Flipper.enabled?(flag)).to be true
    end

    it "keeps a flag disabled when a pause-override is set (the fix)" do
      Flipper.enable(flag) # simulate previous boot's auto-enable
      redis.set(key, "TASK-251.14 backfill")
      boot_decision.call(flag, redis)
      expect(Flipper.enabled?(flag)).to be false
    end

    it "restores auto-enable once the pause key is cleared (no stale state)" do
      redis.set(key, "TASK-251.14 backfill")
      boot_decision.call(flag, redis)
      expect(Flipper.enabled?(flag)).to be false

      redis.del(key)
      boot_decision.call(flag, redis)
      expect(Flipper.enabled?(flag)).to be true
    end

    it "auto-enables when Redis is nil (degraded mode — initializer must not leave flags off)" do
      Flipper.disable(flag)
      boot_decision.call(flag, nil)
      expect(Flipper.enabled?(flag)).to be true
    end
  end
end
