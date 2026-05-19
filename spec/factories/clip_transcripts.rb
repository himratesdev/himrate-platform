# frozen_string_literal: true

FactoryBot.define do
  factory :clip_transcript do
    sequence(:clip_id) { |n| "ClipSlug#{n}" }
    broadcaster_id { "12345" }
    clip_metadata { { title: "Sample Clip", game_id: "21779", duration_sec: 30.0 } }
    status { "queued" }
    segments { [] }
    whisper_cost_cents { 0 }

    trait :done do
      status { "done" }
      cached_at { Time.current }
      segments do
        [
          { "start_sec" => 0.0, "end_sec" => 3.2, "text" => "Hello" },
          { "start_sec" => 3.2, "end_sec" => 6.0, "text" => "world" }
        ]
      end
      whisper_lang { "en" }
    end

    trait :error do
      status { "error" }
      error_message { "Whisper timeout" }
    end
  end
end
