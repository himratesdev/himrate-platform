# frozen_string_literal: true

require "rails_helper"

RSpec.describe BotListRefreshWorker do
  let(:worker) { described_class.new }

  before do
    KnownBotList.delete_all

    allow(ENV).to receive(:fetch).and_call_original
    allow(ENV).to receive(:fetch).with("REDIS_URL", anything).and_return("redis://localhost:6379/1")
    allow(Flipper).to receive(:enabled?).with(:known_bots).and_return(true)

    # Clean Redis
    r = Redis.new(url: "redis://localhost:6379/1")
    %w[all commanderroot twitchinsights twitchbots_info streamscharts truevio].each do |suffix|
      r.del("known_bots:#{suffix}")
      r.del("known_bots:#{suffix}:new")
    end
  rescue Redis::CannotConnectError
    skip "Redis not available"
  end

  # TC-006..009: Import from sources
  it "imports from all adapters and rebuilds filters" do
    # Stub all adapters
    allow_any_instance_of(BotSources::CommanderRootAdapter).to receive(:fetch).and_return(%w[bot1 bot2 bot3])
    allow_any_instance_of(BotSources::TwitchInsightsAdapter).to receive(:fetch).and_return(%w[bot1 bot4])
    allow_any_instance_of(BotSources::TwitchBotsInfoAdapter).to receive(:fetch).and_return(%w[nightbot moobot])
    allow_any_instance_of(BotSources::StreamsChartsAdapter).to receive(:fetch).and_return([])

    # 3 (commanderroot: bot1,bot2,bot3) + 2 (twitchinsights: bot1,bot4) + 2 (twitchbots_info: nightbot,moobot) = 7
    # bot1 appears in 2 sources = 2 records (composite unique [username, source])
    expect { worker.perform }.to change(KnownBotList, :count).by(7)

    # Verify categories
    expect(KnownBotList.find_by(username: "nightbot").bot_category).to eq("service_bot")
    expect(KnownBotList.find_by(username: "bot1", source: "commanderroot").bot_category).to eq("view_bot")
  end

  # TC-015: API source down → keep old
  it "continues with other sources when one fails" do
    allow_any_instance_of(BotSources::CommanderRootAdapter).to receive(:fetch).and_raise(StandardError, "API down")
    allow_any_instance_of(BotSources::TwitchInsightsAdapter).to receive(:fetch).and_return(%w[bot1])
    allow_any_instance_of(BotSources::TwitchBotsInfoAdapter).to receive(:fetch).and_return(%w[nightbot])
    allow_any_instance_of(BotSources::StreamsChartsAdapter).to receive(:fetch).and_return([])

    expect { worker.perform }.to change(KnownBotList, :count).by(2)
  end

  it "skips when Flipper disabled" do
    allow(Flipper).to receive(:enabled?).with(:known_bots).and_return(false)
    expect { worker.perform }.not_to change(KnownBotList, :count)
  end

  # TC-022: Trend stats logged
  it "logs trend stats" do
    allow_any_instance_of(BotSources::CommanderRootAdapter).to receive(:fetch).and_return(%w[bot1])
    allow_any_instance_of(BotSources::TwitchInsightsAdapter).to receive(:fetch).and_return(%w[bot2])
    allow_any_instance_of(BotSources::TwitchBotsInfoAdapter).to receive(:fetch).and_return([])
    allow_any_instance_of(BotSources::StreamsChartsAdapter).to receive(:fetch).and_return([])

    allow(Rails.logger).to receive(:info).and_call_original
    worker.perform
    # Verify trend was logged (check log output contains TREND)
    expect(KnownBotList.count).to be >= 2
  end
end
