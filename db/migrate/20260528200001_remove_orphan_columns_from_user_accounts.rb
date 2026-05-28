# frozen_string_literal: true

# BUG-251.23: drop the remaining 4 orphan columns added to `user_accounts` by
# `20260327100003_add_bot_scoring_fields.rb` (TASK-016 era).
#
# Continuation of BUG-251.22 (which dropped `profile_view_count`). Code-side audit at the
# time of BUG-251.22 revealed all 5 columns added by AddBotScoringFields are dead — bot
# detection moved to `chatter_profiles` long ago and these `user_accounts` columns were
# never read or written by current code:
#
#   * `videos_total_count`  — 0 active references across `app/` `lib/` `spec/` `config/`.
#   * `last_broadcast_at`   — 0 active references; 1 spec nil fixture in
#                              `spec/services/bot_detection/scorer_spec.rb:85`.
#   * `banner_image_url`    — 0 active references; 2 spec mentions
#                              (`chatter_profile_spec` not_to-have_key + scorer_spec nil fixture).
#   * `description`         — 56 hits, ALL for OTHER models (`channel.description`,
#                              `chatter_profile.description` via GQL, `sidekiq_cron description`).
#                              ZERO references to `user_accounts.description` specifically.
#
# The `UserAccount` model itself is a 4-line empty class (`class UserAccount <
# ApplicationRecord; end`), there are no FK constraints referencing `user_accounts`
# (verified via `SELECT … FROM pg_constraint WHERE confrelid = user_accounts AND contype = 'f'`),
# and the table has 0 rows on staging. The entire table is an orphan candidate but
# `drop_table` is deferred — this PR is the conservative single-step cleanup.
#
# Bulk DDL via `change_table … bulk: true` collapses 4 column drops into a single
# `ALTER TABLE` round-trip. `remove_column` is metadata-only on `pg_attribute` (O(1));
# no indexes or FKs to drop concurrently.
#
# Reversible: `down` re-adds all 4 columns with their original types. Data is
# unrecoverable (none was ever populated; `description` / `banner_image_url` would have
# been Twitch GQL hydrated had the code path been kept alive, but it never shipped).
class RemoveOrphanColumnsFromUserAccounts < ActiveRecord::Migration[8.1]
  def up
    change_table :user_accounts, bulk: true do |t|
      t.remove :videos_total_count
      t.remove :last_broadcast_at
      t.remove :description
      t.remove :banner_image_url
    end
  end

  def down
    change_table :user_accounts, bulk: true do |t|
      t.integer :videos_total_count
      t.datetime :last_broadcast_at
      t.text :description
      t.text :banner_image_url
    end
  end
end
