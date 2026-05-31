# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Static configuration" do
  describe "config/sidekiq.yml" do
    let(:config) do
      YAML.safe_load(
        ERB.new(File.read(Rails.root.join("config/sidekiq.yml"))).result,
        permitted_classes: [ Symbol ]
      )
    end

    it "contains 13 queues" do
      # TASK-110 v1.2 (CR S-7): whisper_transcripts НЕ в shared :queues — обрабатывается
      # ТОЛЬКО dedicated whisper_worker role (deploy.yml) для CPU isolation concurrency=1.
      # TASK-113 Δ-1 Wave 1 (FR-016): pva_critical / pva_helix / pva_gql_anon (8 → 11).
      # PR #229 (EPIC BUG-251.28 Phase 5): bot_scoring dedicated queue (11 → 12) so
      # BotScoringWorker bypasses the :signals SignalComputeWorker backlog.
      # Phase 5 follow-up (2026-05-31): signal_compute dedicated queue (12 → 13) so new
      # SignalComputeWorker enqueues bypass the residual :signals 1M+ historical backlog.
      expect(config[:queues].size).to eq(13)
    end

    it "includes required queue names" do
      queue_names = config[:queues].map(&:first)
      expect(queue_names).to include(
        "bot_scoring", "signal_compute", "signals", "chat", "post_stream", "default",
        "notifications", "monitoring", "accessory_ops", "long_running"
      )
    end

    it "does NOT include whisper_transcripts (dedicated role only — CR S-7)" do
      queue_names = config[:queues].map(&:first)
      expect(queue_names).not_to include("whisper_transcripts")
    end

    it "prioritizes signals queue highest" do
      signals_weight = config[:queues].find { |q| q.first == "signals" }&.last
      default_weight = config[:queues].find { |q| q.first == "default" }&.last
      expect(signals_weight).to be > default_weight
    end

    it "signal_compute queue matches bot_scoring priority class (weight 6)" do
      # Phase 5 follow-up (2026-05-31): both queues serve "live freshness" — bot scoring
      # of live streams (PR #229) + TI/ERV recompute on live streams (this PR). Same
      # priority class, so same weight. If this drifts, the lower-weight queue gets
      # starved of fetch share when the other has steady volume.
      signal_compute_weight = config[:queues].find { |q| q.first == "signal_compute" }&.last
      bot_scoring_weight = config[:queues].find { |q| q.first == "bot_scoring" }&.last
      expect(signal_compute_weight).to eq(bot_scoring_weight)
    end

    it "signal_compute queue ranks above signals (new enqueues bypass historical backlog)" do
      signal_compute_weight = config[:queues].find { |q| q.first == "signal_compute" }&.last
      signals_weight = config[:queues].find { |q| q.first == "signals" }&.last
      expect(signal_compute_weight).to be > signals_weight
    end
  end

  describe "config/deploy.yml" do
    let(:deploy) { YAML.safe_load(File.read(Rails.root.join("config/deploy.yml"))) }

    it "env.secret contains FLIPPER_UI_PASSWORD" do
      expect(deploy.dig("env", "secret")).to include("FLIPPER_UI_PASSWORD")
    end

    it "env.secret contains FLIPPER_UI_USER" do
      expect(deploy.dig("env", "secret")).to include("FLIPPER_UI_USER")
    end

    it "env.secret contains ALLOWED_EXTENSION_ID" do
      expect(deploy.dig("env", "secret")).to include("ALLOWED_EXTENSION_ID")
    end

    it "redis accessory uses AOF persistence via REDIS_ARGS" do
      redis_args = deploy.dig("accessories", "redis", "env", "clear", "REDIS_ARGS")
      expect(redis_args).to include("--appendonly yes")
    end
  end

  describe "docker-compose.yml" do
    let(:compose) { YAML.safe_load(File.read(Rails.root.join("docker-compose.yml"))) }

    it "redis uses AOF persistence" do
      redis_command = compose.dig("services", "redis", "command")
      expect(redis_command).to include("--appendonly yes")
    end
  end
end
