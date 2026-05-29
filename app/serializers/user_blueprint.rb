# frozen_string_literal: true

# TASK-031 FR-001/009: User serializer.
#
# BUG-USER-PAYLOAD-TWITCH-LINKED (2026-05-29, CR iter-1 S-1): keep parity с
# Api::V1::AuthController#build_user_payload — extension SidePanel
# `authState.twitchLinked` is rehydrated through BOTH OAuth callback AND
# `GET /api/v1/user/me`. Pre-fix /user/me omitted twitch_linked → reload after login
# brought back the misleading «Привяжите Twitch» banner. Both endpoints now expose
# the same three flags.
class UserBlueprint < Blueprinter::Base
  identifier :id

  fields :username, :email, :display_name, :avatar_url, :role, :tier, :locale

  field :tracked_channels_count do |user, _options|
    user.tracked_channels.size
  end

  field :is_streamer do |user, _options|
    user.role == "streamer"
  end

  field :twitch_linked do |user, _options|
    user.auth_providers.any? { |ap| ap.provider == "twitch" }
  end

  field :twitch_login do |user, _options|
    user.auth_providers.any? { |ap| ap.provider == "twitch" } ? user.username : nil
  end

  field :google_linked do |user, _options|
    user.auth_providers.any? { |ap| ap.provider == "google" }
  end
end
