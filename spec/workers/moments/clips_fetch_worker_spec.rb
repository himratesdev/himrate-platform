# frozen_string_literal: true

require "rails_helper"

RSpec.describe Moments::ClipsFetchWorker do
  let(:channel) { create(:channel, twitch_id: "777001") }
  let(:stream) { create(:stream, channel: channel, started_at: 4.hours.ago, ended_at: 1.hour.ago) }

  it "fetches the stream-window clips via Helix and caches the trimmed payload" do
    helix = instance_double(Twitch::HelixClient)
    allow(Twitch::HelixClient).to receive(:new).and_return(helix)
    expect(helix).to receive(:get_clips)
      .with(broadcaster_id: "777001", first: 50, started_at: stream.started_at, ended_at: stream.ended_at)
      .and_return([ {
        "id" => "Abc", "title" => "t", "url" => "https://clips.twitch.tv/Abc", "view_count" => "12",
        "duration" => 21.5, "thumbnail_url" => "https://thumb", "vod_offset" => 300,
        "created_at" => "2026-07-20T18:05:00Z", "broadcaster_name" => "x", "extra" => "dropped"
      } ])

    described_class.new.perform(stream.id)

    cached = Rails.cache.read(described_class.cache_key(stream.id))
    expect(cached.size).to eq(1)
    expect(cached.first["view_count"]).to eq(12)
    expect(cached.first["vod_offset"]).to eq(300)
    expect(cached.first).not_to have_key("extra")
  end

  it "no-ops for a live (unfinished) stream and clears the pending marker" do
    live = create(:stream, channel: channel, started_at: 1.hour.ago, ended_at: nil)
    Rails.cache.write(described_class.pending_key(live.id), true)
    expect(Twitch::HelixClient).not_to receive(:new)

    described_class.new.perform(live.id)
    expect(Rails.cache.exist?(described_class.pending_key(live.id))).to be(false)
  end
end
