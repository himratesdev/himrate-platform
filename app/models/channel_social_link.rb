# frozen_string_literal: true

# One linked social account of a channel, discovered from Twitch `channel.socialMedias` (SA-2 footprint
# index). Read-mostly: written only by Social::FootprintIndexWorker (delete-then-insert per channel).
# Descriptive identity/footprint — NOT a fraud signal.
class ChannelSocialLink < ApplicationRecord
  belongs_to :channel

  # Platforms our per-platform adapters can actually analyse (rest = display-only footprint).
  ANALYZABLE_PLATFORMS = SocialAnalytics::TwitchSocials::ANALYZABLE

  validates :platform, :url, presence: true

  scope :on_platform, ->(platform) { where(platform: platform.to_s) }
  scope :analyzable, -> { where(analyzable: true) }
end
