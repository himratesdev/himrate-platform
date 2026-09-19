# frozen_string_literal: true

require "rails_helper"

# WEB-CONSOLIDATION: a channel's best clips right now — public, like the rest of the card.
RSpec.describe "Api::V1::Channels clips", type: :request do
  let(:channel) { create(:channel, login: "clipper", twitch_id: "777000") }

  def clip(slug, views:, **attrs)
    create(:farm_clip, clip_id: slug, view_count: views, broadcaster_twitch_id: channel.twitch_id, **attrs)
  end

  it "answers a guest with the channel's clips, best first" do
    clip("top_one", views: 5_000)
    clip("second", views: 400)

    get "/api/v1/channels/clipper/clips"

    expect(response).to have_http_status(:ok)
    data = response.parsed_body["data"]
    expect(data["login"]).to eq("clipper")
    expect(data["clips"].map { |c| c["clip_id"] }).to eq(%w[top_one second])
  end

  it "serves the fields a reader needs to show and embed a clip" do
    clip("shown_slug", views: 1_234, title: "Момент", duration: 28.5, vod_offset: 3_600,
                       twitch_created_at: Time.utc(2026, 9, 1, 10, 0, 0))

    get "/api/v1/channels/clipper/clips"

    row = response.parsed_body["data"]["clips"].sole
    expect(row).to eq(
      "clip_id" => "shown_slug",
      "embed_slug" => "shown_slug",
      "url" => "https://clips.twitch.tv/shown_slug",
      "title" => "Момент",
      "thumbnail_url" => "https://clips-media-assets2.twitch.tv/shown_slug-preview.jpg",
      "view_count" => 1_234,
      "duration" => 28.5,
      "vod_offset" => 3_600,
      "created_at" => "2026-09-01T10:00:00Z"
    )
  end

  it "honours limit and caps it at 24" do
    30.times { |i| clip("c#{i.to_s.rjust(2, '0')}", views: 1_000 - i) }

    get "/api/v1/channels/clipper/clips", params: { limit: 3 }
    expect(response.parsed_body["data"]["clips"].size).to eq(3)

    get "/api/v1/channels/clipper/clips", params: { limit: 100 }
    expect(response.parsed_body["data"]["clips"].size).to eq(24)
  end

  it "defaults to 12 clips" do
    20.times { |i| clip("d#{i.to_s.rjust(2, '0')}", views: 1_000 - i) }

    get "/api/v1/channels/clipper/clips"

    expect(response.parsed_body["data"]["clips"].size).to eq(12)
  end

  it "returns an empty list for a known channel we have no clips of — not a 404" do
    channel # the channel exists, the farm just never captured a clip of it

    get "/api/v1/channels/clipper/clips"

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body["data"]).to eq("login" => "clipper", "clips" => [])
  end

  it "never serves another broadcaster's clips" do
    clip("ours", views: 10)
    create(:farm_clip, clip_id: "theirs", view_count: 9_000, broadcaster_twitch_id: "111222")

    get "/api/v1/channels/clipper/clips"

    expect(response.parsed_body["data"]["clips"].map { |c| c["clip_id"] }).to eq(%w[ours])
  end

  it "404s an unknown channel" do
    get "/api/v1/channels/nobody_here/clips"

    expect(response).to have_http_status(:not_found)
  end
end
