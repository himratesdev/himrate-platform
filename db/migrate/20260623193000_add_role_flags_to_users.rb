# frozen_string_literal: true

# T1-060 FR-1 (phase-1): the stored is_streamer role flag, replacing the streamer half of
# the mutually-exclusive users.role scalar. viewer = implicit (any registered user). The
# brand role is NOT stored — it derives at read-time from business access (User#brand?),
# because business status is our own internal data and a stored flag would drift; only
# is_streamer needs storing (it captures an external Twitch broadcaster_type signal).
# role stays write-through-synced this phase; dropped in the phase-2 follow-up TASK.
#
# Partial index (WHERE flag = true) mirrors 20260520100005_add_premium_active_to_users.
# add_column null:false default:false = PG11+ fast-default (no table rewrite); users is a
# bounded OLTP table so the in-transaction backfill is acceptable (see ADR DEC-7).
class AddRoleFlagsToUsers < ActiveRecord::Migration[8.0]
  def up
    add_column :users, :is_streamer, :boolean, null: false, default: false
    add_index :users, :is_streamer, where: "is_streamer = true"

    Users::RoleFlagBackfill.run!
  end

  def down
    remove_column :users, :is_streamer
  end
end
