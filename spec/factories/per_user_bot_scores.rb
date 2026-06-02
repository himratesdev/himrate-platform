# frozen_string_literal: true

# EPIC ML-FEATURE-EXTRACTOR PR4: factory для PerUserBotScore.
# AccountSignals reads stream.per_user_bot_scores.pluck(:username) to discover the stream's
# chatters → joins to ChatterProfile.where(login: ...). Factory needs only stream + username
# + bot_score (NOT NULL); confidence + components have safe defaults.
FactoryBot.define do
  factory :per_user_bot_score do
    association :stream
    sequence(:username) { |n| "chatter_#{n}" }
    bot_score { 0.1 }
    confidence { 0.5 }
    components { {} }
  end
end
