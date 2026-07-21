# frozen_string_literal: true

# Records a user lifecycle event. Single entry point so every producer writes the
# same shape and future campaign dispatch hooks in one place (when the first
# action-triggered campaign is defined, it subscribes here). (email-marketing foundation)
module UserEvents
  class Recorder
    def self.record(user, event_type, metadata = {}, occurred_at: Time.current)
      UserEvent.create!(
        user: user,
        event_type: event_type,
        metadata: metadata,
        occurred_at: occurred_at
      )
    end
  end
end
