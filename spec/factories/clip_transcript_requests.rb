# frozen_string_literal: true

FactoryBot.define do
  factory :clip_transcript_request do
    user
    association :clip_transcript, factory: :clip_transcript
    clip_transcript_id { clip_transcript&.clip_id }
    requested_at { Time.current }
  end
end
