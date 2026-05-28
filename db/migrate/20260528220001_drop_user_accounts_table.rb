# frozen_string_literal: true

# BUG-251.25: drop the `user_accounts` table entirely.
#
# Closure of today's user_accounts cleanup series:
#   * PR #208 (TASK-251.20)  — code-side removed `profile_view_count` reads/writes
#   * PR #211 (TASK-251.20)  — dropped twin column on `chatter_profiles`
#   * PR #214 (BUG-251.22)   — dropped `user_accounts.profile_view_count`
#   * PR #215 (BUG-251.23)   — dropped the 4 remaining orphan columns added by
#                              20260327100003_add_bot_scoring_fields
#   * THIS PR (BUG-251.25)   — drops the whole table + empty model
#
# After #214 + #215 the table was reduced to its original `CreateUserDataTables` core
# (id / username / twitch_id / created_at / followers_total / follows_total / is_partner /
# is_affiliate / last_updated_at). Whole-table audit on `origin/main = e0bd2a8`:
#
#   * `app/models/user_account.rb` is a 4-line empty class — no associations, no
#     validations, no callbacks, no scopes.
#   * `grep "UserAccount\b"` across app/ lib/ spec/ config/ returns zero hits other than
#     the model file itself.
#   * Zero foreign-key constraints reference `user_accounts`
#     (`SELECT … FROM pg_constraint WHERE confrelid = user_accounts AND contype = 'f'` → 0).
#   * Zero rows on staging.
#   * Schema fully duplicates `channels` (twitch_id / username / followers_total /
#     is_partner / is_affiliate) — the streamer-profile path migrated to that table
#     long ago.
#   * Zero references in ANY planning artifact: PROJECT_STATE.md, PARALLEL_BOARD.md,
#     ai-dev-team/CLAUDE.md, TASK-251.14 SRS/ADR/CONTEXT, BFT, canonical-task-scope-v2.md,
#     or any `_tasks/` doc other than the BUG-251.22/23/25 records themselves.
#
# Companion change: `app/models/user_account.rb` is deleted in the same commit.
#
# `drop_table` on a 0-row table is a metadata-only ALTER in PG (catalog + dependent
# index drop in `pg_class` / `pg_index`); no row scan, no rewrite. Sub-second.
#
# Reversibility: `down` recreates the table with the original `CreateUserDataTables`
# schema (the core that existed before the TASK-016 `AddBotScoringFields` migration
# added 5 columns). Restoring those 5 columns is the responsibility of THIS PR's
# `down` — the `AddBotScoringFields` migration was already in `schema_migrations` and
# the column drops (#214 + #215) had their own reversible `down` paths, but a rollback
# of BUG-251.25 cannot revert into a non-existent table state. So the down here
# faithfully recreates the schema as of `e0bd2a8` (post-#214 / #215, pre-#217).
class DropUserAccountsTable < ActiveRecord::Migration[8.1]
  def up
    drop_table :user_accounts
  end

  def down
    create_table :user_accounts, id: :uuid do |t|
      t.string :username, limit: 255, null: false
      t.string :twitch_id, limit: 50
      t.datetime :created_at
      t.integer :followers_total
      t.integer :follows_total
      t.boolean :is_partner, null: false, default: false
      t.boolean :is_affiliate, null: false, default: false
      t.datetime :last_updated_at
    end
    add_index :user_accounts, :username, unique: true
    add_index :user_accounts, :twitch_id, unique: true
  end
end
