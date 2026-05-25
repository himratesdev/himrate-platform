# frozen_string_literal: true

require "rails_helper"

RSpec.describe LiveBotScoringWorker do
  let(:worker) { described_class.new }

  before do
    allow(Flipper).to receive(:enabled?).with(:stream_monitor).and_return(true)
    allow(Flipper).to receive(:enabled?).with(:bot_scoring).and_return(true)
    allow(BotScoringWorker).to receive(:perform_async)
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

  it "bounds the number of streams enqueued per run (MAX_STREAMS_PER_RUN)" do
    stub_const("LiveBotScoringWorker::MAX_STREAMS_PER_RUN", 1)
    create(:stream, ended_at: nil)
    create(:stream, ended_at: nil)

    worker.perform

    expect(BotScoringWorker).to have_received(:perform_async).exactly(1).time
  end
end
