# frozen_string_literal: true

# TASK-036 CR fixes:
# M3: team_id → team_owner_id (explicit FK semantics)
# N2: DB-level CHECK on watchlist_channels count (race condition protection)
class CrFixesRenameTeamIdAndAddConstraints < ActiveRecord::Migration[8.0]
  def up
    rename_column :watchlists, :team_id, :team_owner_id

    # N2: DB-level limit — prevents race condition on concurrent POSTs
    execute <<~SQL
      CREATE OR REPLACE FUNCTION check_watchlist_channel_limit()
      RETURNS TRIGGER AS $$
      BEGIN
        IF (SELECT COUNT(*) FROM watchlist_channels WHERE watchlist_id = NEW.watchlist_id) >= 100 THEN
          RAISE EXCEPTION 'Watchlist channel limit (100) exceeded';
        END IF;
        RETURN NEW;
      END;
      $$ LANGUAGE plpgsql;

      CREATE TRIGGER watchlist_channel_limit_trigger
        BEFORE INSERT ON watchlist_channels
        FOR EACH ROW
        EXECUTE FUNCTION check_watchlist_channel_limit();
    SQL
  end

  def down
    execute <<~SQL
      DROP TRIGGER IF EXISTS watchlist_channel_limit_trigger ON watchlist_channels;
      DROP FUNCTION IF EXISTS check_watchlist_channel_limit();
    SQL

    rename_column :watchlists, :team_owner_id, :team_id
  end
end
