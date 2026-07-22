# frozen_string_literal: true

require "rails_helper"

RSpec.describe LiveBotScoringWorker do
  let(:worker) { described_class.new }

  before do
    allow(Flipper).to receive(:enabled?).with(:stream_monitor).and_return(true)
    allow(Flipper).to receive(:enabled?).with(:bot_scoring).and_return(true)
    allow(BotScoringWorker).to receive(:perform_async)
  end

  # Phase 5 (2026-05-31): pairs with BotScoringWorker on the dedicated :bot_scoring queue.
  it "uses the dedicated :bot_scoring queue" do
    expect(described_class.sidekiq_options["queue"]).to eq("bot_scoring")
  end

  it "enqueues BotScoringWorker for each live stream, skipping ended ones" do
    live = create(:stream, ended_at: nil)
    create(:stream, ended_at: 1.hour.ago) # ended → not enqueued

    worker.perform

    expect(BotScoringWorker).to have_received(:perform_async).with(live.id).once
    expect(BotScoringWorker).to have_received(:perform_async).exactly(1).time
  end

  it "does nothing when :bot_scoring is disabled (kill-switch)" do
    allow(Flipper).to receive(:enabled?).with(:bot_scoring).and_return(false)
    create(:stream, ended_at: nil)

    worker.perform

    expect(BotScoringWorker).not_to have_received(:perform_async)
  end

  it "does nothing when :stream_monitor is disabled" do
    allow(Flipper).to receive(:enabled?).with(:stream_monitor).and_return(false)
    create(:stream, ended_at: nil)

    worker.perform

    expect(BotScoringWorker).not_to have_received(:perform_async)
  end

  # BUG-C PR-C2: rotation by least-recently-scored (bot_scored_at ASC NULLS FIRST) instead of
  # oldest-started-first — never-scored (young) streams get priority so they aren't starved at
  # >MAX_STREAMS_PER_RUN concurrent live streams.
  it "bounds streams per run (least-recently-scored first) and warns when the cap binds" do
    stub_const("LiveBotScoringWorker::MAX_STREAMS_PER_RUN", 1)
    scored = create(:stream, ended_at: nil, started_at: 3.hours.ago, bot_scored_at: 1.minute.ago)
    never = create(:stream, ended_at: nil, started_at: 10.minutes.ago, bot_scored_at: nil)
    expect(Rails.logger).to receive(:warn).with(/MAX_STREAMS_PER_RUN/)

    worker.perform

    expect(BotScoringWorker).to have_received(:perform_async).with(never.id).once
    expect(BotScoringWorker).to have_received(:perform_async).exactly(1).time
    expect(scored.reload.bot_scored_at).to be_within(2.seconds).of(1.minute.ago) # not re-scored this run
  end

  it "stamps bot_scored_at on the enqueued streams so the rotation advances next run" do
    s = create(:stream, ended_at: nil, bot_scored_at: nil)
    worker.perform
    expect(s.reload.bot_scored_at).to be_present
    expect(s.bot_scored_at).to be_within(5.seconds).of(Time.current)
    expect(BotScoringWorker).to have_received(:perform_async).with(s.id)
  end
end
