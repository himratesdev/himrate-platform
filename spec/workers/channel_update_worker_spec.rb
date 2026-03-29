# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChannelUpdateWorker do
  let(:worker) { described_class.new }
  let(:channel) { create(:channel, twitch_id: "12345", login: "teststreamer") }

  # TC-020: Updates Stream on channel.update
  it "updates active Stream title and game_name" do
    stream = create(:stream, channel: channel, ended_at: nil, title: "Old Title", game_name: "Fortnite")

    worker.perform({
      "broadcaster_user_id" => channel.twitch_id,
      "title" => "New Title",
      "category_name" => "Just Chatting"
    })

    stream.reload
    expect(stream.title).to eq("New Title")
    expect(stream.game_name).to eq("Just Chatting")
  end

  # TC-021: Skip if no active stream
  it "skips if no active stream" do
    create(:stream, channel: channel, ended_at: 1.hour.ago, title: "Old")

    expect {
      worker.perform({
        "broadcaster_user_id" => channel.twitch_id,
        "title" => "New",
        "category_name" => "JC"
      })
    }.not_to raise_error
  end

  it "skips if channel not found" do
    expect {
      worker.perform({ "broadcaster_user_id" => "99999", "title" => "X", "category_name" => "Y" })
    }.not_to raise_error
  end
end
