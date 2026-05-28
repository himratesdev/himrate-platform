# frozen_string_literal: true

# BUG-251.22: drop the `profile_view_count` column from `user_accounts`.
#
# Background: PR #208 (TASK-251.20, code-only) removed every reader/writer of
# `profile_view_count` from the codebase — the BotDetection::Scorer
# `profile[:profile_view_count]&.zero?` predicate, the Twitch GQL `profileViewCount`
# field, the ChatterProfile / ChatterProfileRefreshWorker references, the spec
# fixtures. Twitch deprecated the GQL field (Jul 2025).
#
# PR #211 dropped the twin column on `chatter_profiles`. This PR drops the original
# column added in `20260327100003_add_bot_scoring_fields.rb` (TASK-016 era), which is
# now an orphan: 0 active code references on `main` (only comments remain), 0 populated
# values on staging (the `user_accounts` table is empty at the time of this drop — the
# user-side path migrated to the `users` table; `user_accounts` retains the auth_provider
# linkage but never repopulated this column after the scorer stopped writing).
#
# Single-PR shape (no 2-PR split like #208/#211): the code-removal happened in #208
# ~3 h before this ships. Rolling-deploy safety:
#   * Sidekiq workers on the previous image (`fb6dac9` / `96beab7`) already ran code
#     without any `profile_view_count` reads/writes — no cached `columns_hash` reference.
#   * New image will not see the column either.
#   * No active reader/writer = no error path during the window where the migration
#     runs and OLD workers are still up.
#
# Reversible: `down` re-adds the column as integer (data is unrecoverable — the source
# Twitch GQL field is gone — documented for completeness).
#
# Concurrent path NOT needed: PG `remove_column` is metadata-only via pg_attribute (O(1)),
# no btree/FK on `profile_view_count` (added as a plain integer in 20260327100003,
# never indexed).
#
# Out of scope (deferred follow-up): the same `AddBotScoringFields` migration also
# added `videos_total_count`, `last_broadcast_at`, `description`, `banner_image_url`
# to `user_accounts`. Of those, `videos_total_count` is similarly orphan (0 refs),
# the others have spec-fixture mentions worth a deeper audit. Tracked separately.
class RemoveProfileViewCountFromUserAccounts < ActiveRecord::Migration[8.1]
  def up
    remove_column :user_accounts, :profile_view_count
  end

  def down
    add_column :user_accounts, :profile_view_count, :integer
  end
end
