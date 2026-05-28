# frozen_string_literal: true

require "rails_helper"
require "rake"

# BUG-251.21: operator UX for the pause-override Redis key pattern.
RSpec.describe "flipper:pause rake tasks" do
  let(:redis_url) { "redis://localhost:6379/1" }
  let(:redis) { Redis.new(url: redis_url) }
  let(:flag) { "signal_compute" }
  let(:key) { "#{FlipperDefaults::PAUSE_KEY_PREFIX}:#{flag}" }

  before(:all) { Rails.application.load_tasks if Rake::Task.tasks.empty? }

  before do
    skip "Redis not available" unless redis.ping == "PONG"
    Rake::Task.tasks.each(&:reenable)
    # Clean pause-override namespace so each example starts fresh
    redis.scan_each(match: "#{FlipperDefaults::PAUSE_KEY_PREFIX}:*").each { |k| redis.del(k) }
    allow(ENV).to receive(:fetch).and_call_original
    allow(ENV).to receive(:fetch).with("REDIS_URL", anything).and_return(redis_url)
  rescue Redis::CannotConnectError
    skip "Redis not reachable"
  end

  after do
    redis&.scan_each(match: "#{FlipperDefaults::PAUSE_KEY_PREFIX}:*")&.each { |k| redis.del(k) }
  end

  describe "flipper:pause:list" do
    it "prints 'No active pause-overrides.' when empty" do
      expect { Rake::Task["flipper:pause:list"].invoke }.to output(/No active pause-overrides/).to_stdout
    end

    it "lists active pause-overrides with their reason" do
      redis.set("#{FlipperDefaults::PAUSE_KEY_PREFIX}:signal_compute", "TASK-251.14 backfill")
      redis.set("#{FlipperDefaults::PAUSE_KEY_PREFIX}:bot_scoring", "TASK-251.14 backfill")

      expect { Rake::Task["flipper:pause:list"].invoke }.to output(
        a_string_matching(/Active pause-overrides \(2\)/).and(
          a_string_matching(/signal_compute.*backfill/).and(a_string_matching(/bot_scoring.*backfill/))
        )
      ).to_stdout
    end
  end

  describe "flipper:pause:set" do
    it "aborts when flag is missing" do
      expect { Rake::Task["flipper:pause:set"].invoke }.to raise_error(SystemExit)
    end

    it "aborts when reason is missing (audit trail required)" do
      expect { Rake::Task["flipper:pause:set"].invoke("signal_compute") }.to raise_error(SystemExit)
    end

    it "aborts on unknown flag (typo protection)" do
      expect { Rake::Task["flipper:pause:set"].invoke("not_a_flag", "reason") }.to raise_error(SystemExit)
    end

    it "writes the pause-override key + reason for a valid ALL_FLAGS flag" do
      expect { Rake::Task["flipper:pause:set"].invoke("signal_compute", "TASK-251.14 backfill") }
        .to output(/pause-override SET.*flipper:pause_override:signal_compute.*TASK-251\.14/m).to_stdout
      expect(redis.get(key)).to eq("TASK-251.14 backfill")
    end

    it "accepts HOOK_FLAGS keys as well (operator flexibility) and warns that pause has no boot effect" do
      # CR-iter1 #3: HOOK_FLAGS aren't auto-enabled at boot, so the pause-override key
      # is harmless but doesn't change anything. The operator UX should make that explicit.
      expect { Rake::Task["flipper:pause:set"].invoke("trends_pdf_export", "hold for QA") }
        .to output(
          a_string_matching(/pause-override SET/).and(
            a_string_matching(/trends_pdf_export is in HOOK_FLAGS.*never auto-enabled.*no effect at boot/m)
          )
        ).to_stdout
      expect(redis.get("#{FlipperDefaults::PAUSE_KEY_PREFIX}:trends_pdf_export")).to eq("hold for QA")
    end

    it "for an ALL_FLAGS flag shows the gem-agnostic Rails immediate-effect hint (not redis-cli HDEL)" do
      # CR-iter1 #5: prefer `Flipper.disable(:flag)` via runner over `HDEL <flag> boolean` —
      # the latter depends on Flipper's storage layout (rots on a major gem bump).
      expect { Rake::Task["flipper:pause:set"].invoke("signal_compute", "TASK-251.14 backfill") }
        .to output(a_string_matching(/bin\/rails runner.*Flipper\.disable\(:signal_compute\)/)).to_stdout
    end

    it "overwrites an existing pause-override (last-write-wins)" do
      Rake::Task["flipper:pause:set"].invoke("signal_compute", "first reason")
      Rake::Task["flipper:pause:set"].reenable
      Rake::Task["flipper:pause:set"].invoke("signal_compute", "second reason")
      expect(redis.get(key)).to eq("second reason")
    end
  end

  describe "flipper:pause:clear" do
    it "aborts when flag is missing" do
      expect { Rake::Task["flipper:pause:clear"].invoke }.to raise_error(SystemExit)
    end

    it "no-ops when nothing is set" do
      expect { Rake::Task["flipper:pause:clear"].invoke("signal_compute") }
        .to output(/no-op.*no pause-override was set for signal_compute/).to_stdout
    end

    it "deletes an existing pause-override and confirms" do
      redis.set(key, "TASK-251.14 backfill")
      expect { Rake::Task["flipper:pause:clear"].invoke("signal_compute") }
        .to output(/pause-override CLEARED.*flipper:pause_override:signal_compute/m).to_stdout
      expect(redis.get(key)).to be_nil
    end
  end

  describe "flipper:pause:clear_all" do
    it "prints a no-op message when there are no pauses" do
      expect { Rake::Task["flipper:pause:clear_all"].invoke }.to output(/No pause-overrides to clear/).to_stdout
    end

    it "clears every flipper:pause_override:* key and reports the count" do
      redis.set("#{FlipperDefaults::PAUSE_KEY_PREFIX}:signal_compute", "r1")
      redis.set("#{FlipperDefaults::PAUSE_KEY_PREFIX}:bot_scoring", "r2")
      expect { Rake::Task["flipper:pause:clear_all"].invoke }
        .to output(/Cleared 2 key\(s\)/).to_stdout
      expect(redis.scan_each(match: "#{FlipperDefaults::PAUSE_KEY_PREFIX}:*").to_a).to be_empty
    end
  end

  describe "flipper:pause:flags" do
    it "lists ALL_FLAGS and HOOK_FLAGS for operator targeting" do
      expect { Rake::Task["flipper:pause:flags"].invoke }.to output(
        a_string_matching(/ALL_FLAGS.*bot_scoring.*signal_compute/m).and(
          a_string_matching(/HOOK_FLAGS.*trends_pdf_export/m)
        )
      ).to_stdout
    end
  end
end
