# frozen_string_literal: true

# TASK-251.B: idempotency key for RaidDetectionWorker. Each raid is captured once as an IRC
# USERNOTICE whose `id` tag (chat_messages.twitch_msg_id) is globally unique per Twitch; storing it
# on the attribution lets the worker skip raids it has already classified. Partial unique index
# (WHERE NOT NULL) — pre-existing rows from the old EventSub stub path carry no msg id and stay
# allowed. The index builds inline (not concurrently): raid_attributions is empty when CI migrates
# from scratch and ~1 row on staging, with no concurrent writer, so there is no lock contention
# (the concurrent-index rule from BUG-012 is for large write-busy tables like channels). It grows
# ~500 rows/day afterward.
class AddTwitchMsgIdToRaidAttributions < ActiveRecord::Migration[8.0]
  def change
    add_column :raid_attributions, :twitch_msg_id, :string, limit: 255
    add_index :raid_attributions, :twitch_msg_id, unique: true, where: "twitch_msg_id IS NOT NULL"
  end
end
