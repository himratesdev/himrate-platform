# frozen_string_literal: true

# TASK-036 FR-018: Data migration from jsonb array to join table.
# Staging is empty, but migration is fully reversible.
class MigrateChannelsListToJoinTable < ActiveRecord::Migration[8.0]
  def up
    execute <<~SQL
      INSERT INTO watchlist_channels (id, watchlist_id, channel_id, added_at)
      SELECT gen_random_uuid(), w.id, ch.id, NOW()
      FROM watchlists w,
           LATERAL jsonb_array_elements_text(w.channels_list) AS cid
           JOIN channels ch ON ch.id::text = cid
      WHERE jsonb_array_length(w.channels_list) > 0
      ON CONFLICT (watchlist_id, channel_id) DO NOTHING
    SQL
  end

  def down
    execute <<~SQL
      UPDATE watchlists w
      SET channels_list = COALESCE(
        (SELECT jsonb_agg(wc.channel_id::text)
         FROM watchlist_channels wc
         WHERE wc.watchlist_id = w.id),
        '[]'::jsonb
      )
    SQL
  end
end
