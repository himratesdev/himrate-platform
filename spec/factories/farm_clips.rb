# frozen_string_literal: true

# EPIC FARM: one Twitch clip in a farmed category's pool (Farm::ClipsPollerWorker upserts these).
# broadcaster_twitch_id is what joins a clip to a Channel — set it from the channel under test.
FactoryBot.define do
  factory :farm_clip do
    sequence(:clip_id) { |n| "CleverSlugNumber#{n}" }
    game_id { "493057" }
    sequence(:broadcaster_twitch_id) { |n| "broadcaster_#{n}" }
    broadcaster_name { "Broadcaster" }
    title { "Момент эфира" }
    language { "ru" }
    url { "https://clips.twitch.tv/#{clip_id}" }
    thumbnail_url { "https://clips-media-assets2.twitch.tv/#{clip_id}-preview.jpg" }
    view_count { 100 }
    duration { 30.5 }
    vod_offset { 1_200 }
    twitch_created_at { 2.days.ago }
    first_seen_at { 2.days.ago }
    last_seen_at { 1.hour.ago }
  end
end
