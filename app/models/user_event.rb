# frozen_string_literal: true

# One row per meaningful user action — the substrate for action-triggered email
# campaigns. Append-only: never updated or deleted (except cascade on user delete).
# event_type is intentionally an open string; the known set grows as campaigns are
# added. Emitted via UserEvents::Recorder.
class UserEvent < ApplicationRecord
  belongs_to :user

  # Known event types (documentation + a light guard). Adding a campaign trigger =
  # add its type here and emit it via UserEvents::Recorder.
  REGISTERED = "registered"
  KNOWN_TYPES = [ REGISTERED ].freeze

  validates :event_type, presence: true
  validates :occurred_at, presence: true

  scope :of_type, ->(type) { where(event_type: type) }
end
