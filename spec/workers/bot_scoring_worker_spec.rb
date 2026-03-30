# frozen_string_literal: true

require "rails_helper"

RSpec.describe BotScoringWorker do
  let(:worker) { described_class.new }

  before do
    allow(Flipper).to receive(:enabled?).with(:bot_scoring).and_return(true)
  end

  # AC-09: BotScoringWorker batch scores all chatters after stream ends
  it "scores chatters and writes to per_user_bot_scores" do
    channel = Channel.create!(twitch_id: "123", login: "test_channel", display_name: "Test")
    stream = Stream.create!(channel: channel, started_at: 2.hours.ago, ended_at: 1.hour.ago)

    # Create chat messages
    3.times do |i|
      ChatMessage.create!(
        stream: stream,
        channel_login: "test_channel",
        username: "user_#{i}",
        message_text: "hello #{i}",
        timestamp: 90.minutes.ago + i.minutes,
        msg_type: "privmsg"
      )
    end

    # Stub KnownBotService
    allow_any_instance_of(KnownBotService).to receive(:check_batch).and_return(
      "user_0" => { bot: false, confidence: 0.0, sources: [] },
      "user_1" => { bot: false, confidence: 0.0, sources: [] },
      "user_2" => { bot: false, confidence: 0.0, sources: [] }
    )

    expect { worker.perform(stream.id) }.to change(PerUserBotScore, :count).by(3)

    scores = PerUserBotScore.where(stream: stream)
    expect(scores.pluck(:username)).to contain_exactly("user_0", "user_1", "user_2")
    scores.each do |s|
      expect(s.bot_score).to be_between(0.0, 1.0)
      expect(s.classification).to be_in(PerUserBotScore::CLASSIFICATIONS)
      expect(s.components).to be_a(Hash)
    end
  end

  it "skips when Flipper disabled" do
    allow(Flipper).to receive(:enabled?).with(:bot_scoring).and_return(false)
    expect { worker.perform("some-id") }.not_to change(PerUserBotScore, :count)
  end

  it "handles missing stream gracefully" do
    expect { worker.perform("nonexistent-id") }.not_to raise_error
  end

  it "handles stream with 0 chatters" do
    channel = Channel.create!(twitch_id: "456", login: "empty_channel", display_name: "Empty")
    stream = Stream.create!(channel: channel, started_at: 2.hours.ago, ended_at: 1.hour.ago)

    allow_any_instance_of(KnownBotService).to receive(:check_batch).and_return({})

    expect { worker.perform(stream.id) }.not_to change(PerUserBotScore, :count)
  end
end
