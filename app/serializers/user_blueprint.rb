# frozen_string_literal: true

# TASK-031 FR-001/009: User serializer.

class UserBlueprint < Blueprinter::Base
  identifier :id

  fields :username, :email, :display_name, :avatar_url, :role, :tier, :locale

  field :tracked_channels_count do |user, _options|
    user.tracked_channels.size
  end

  field :is_streamer do |user, _options|
    user.role == "streamer"
  end
end
