# frozen_string_literal: true

# TASK-039 Visual QA: tracks synthetic channels created by `trends:visual_qa:seed`
# для safe idempotent re-run + full teardown.
#
# NEVER exists в production env — создаётся только staging/development через rake task.

class VisualQaChannelSeed < ApplicationRecord
  belongs_to :channel

  validates :seed_profile, presence: true
  validates :seeded_at, presence: true
  validates :schema_version, presence: true, numericality: { greater_than: 0 }
end
