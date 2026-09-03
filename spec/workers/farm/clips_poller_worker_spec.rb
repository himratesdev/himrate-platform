# frozen_string_literal: true

require "rails_helper"

RSpec.describe Farm::ClipsPollerWorker do
  let(:helix) { instance_double(Twitch::HelixClient) }

  before do
    allow(Twitch::HelixClient).to receive(:new).and_return(helix)
    Flipper.enable(:farm_clips_poller)
  end

  def clip_payload(id, views: 10, game_id: "493057", **over)
    {
      "id" => id, "game_id" => game_id, "broadcaster_id" => "111", "broadcaster_name" => "str",
      "creator_id" => "222", "creator_name" => "clipper", "title" => "t", "language" => "ru",
      "url" => "https://clips.twitch.tv/#{id}", "video_id" => "900", "thumbnail_url" => "https://th",
      "view_count" => views, "duration" => 21.5, "vod_offset" => 300, "is_featured" => false,
      "created_at" => "2026-09-02T18:05:00Z"
    }.merge(over)
  end

  it "paginates the category pool, upserts clips and records view snapshots" do
    expect(helix).to receive(:get_clips_by_game)
      .with(hash_including(game_id: "493057", first: 100, after: nil))
      .and_return({ "data" => [ clip_payload("A", views: 5) ], "cursor" => "cur1" })
    expect(helix).to receive(:get_clips_by_game)
      .with(hash_including(after: "cur1"))
      .and_return({ "data" => [ clip_payload("B", views: 7) ], "cursor" => nil })

    described_class.new.perform

    expect(FarmClip.pluck(:clip_id)).to contain_exactly("A", "B")
    expect(FarmClip.find_by(clip_id: "A").view_snapshots.pluck(:view_count)).to eq([ 5 ])
  end

  it "re-polling an existing clip updates view_count and appends a snapshot (velocity source)" do
    allow(helix).to receive(:get_clips_by_game)
      .and_return({ "data" => [ clip_payload("A", views: 5) ], "cursor" => nil })
    described_class.new.perform
    FarmClipViewSnapshot.update_all(captured_at: 3.hours.ago) # прошлый 3h-цикл

    allow(helix).to receive(:get_clips_by_game)
      .and_return({ "data" => [ clip_payload("A", views: 50) ], "cursor" => nil })
    described_class.new.perform

    clip = FarmClip.find_by(clip_id: "A")
    expect(clip.view_count).to eq(50)
    expect(clip.view_snapshots.order(:captured_at).pluck(:view_count)).to eq([ 5, 50 ])
    expect(FarmClip.count).to eq(1)
  end

  it "does not duplicate a fresh snapshot when a retry re-walks the same clip (idempotency guard)" do
    allow(helix).to receive(:get_clips_by_game)
      .and_return({ "data" => [ clip_payload("A", views: 5) ], "cursor" => nil })

    described_class.new.perform
    described_class.new.perform # Sidekiq retry seconds later

    expect(FarmClip.find_by(clip_id: "A").view_snapshots.count).to eq(1)
  end

  it "drops clips whose own game_id differs from the polled category (leak defense)" do
    allow(helix).to receive(:get_clips_by_game)
      .and_return({ "data" => [ clip_payload("DOTA", game_id: "29595") ], "cursor" => nil })

    described_class.new.perform

    expect(FarmClip.count).to eq(0)
  end

  it "is a no-op when the farm_clips_poller flag is disabled" do
    Flipper.disable(:farm_clips_poller)
    expect(Twitch::HelixClient).not_to receive(:new)

    described_class.new.perform
  end
end
