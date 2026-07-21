# frozen_string_literal: true

# One descriptive snapshot of a streamer's social platform (SA-1). The time series enables
# «рост подписчиков» once it accumulates. Descriptive only — no fraud verdict.
class SocialProfileSnapshot < ApplicationRecord
  validates :twitch_login, :platform, :captured_at, presence: true

  scope :for_login, ->(login) { where(twitch_login: login.to_s.strip.downcase) }
  scope :on_platform, ->(platform) { where(platform: platform.to_s) }
end
