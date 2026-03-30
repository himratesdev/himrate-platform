# frozen_string_literal: true

# TASK-031 FR-001/009: User serializer.

class UserBlueprint < Blueprinter::Base
  identifier :id

  # Users table columns: username, email, role, tier, goal_tag
  # display_name and avatar_url are in auth_providers (Twitch/Google profile data)
  fields :username, :email, :role, :tier

  field :tracked_channels_count do |user, _options|
    user.tracked_channels.size
  end

  field :is_streamer do |user, _options|
    user.role == "streamer"
  end
end
