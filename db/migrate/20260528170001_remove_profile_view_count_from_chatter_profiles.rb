# frozen_string_literal: true

# TASK-251.20 follow-up: drop `profile_view_count` column from `chatter_profiles`.
#
# Background: TASK-251.20 (PR #208, merged 2026-05-28 13:17:43Z, deployed 13:36 +3h ago by the
# time this migration ships) removed all writers and readers of `profile_view_count` from the
# codebase (BotDetection::Scorer, ChatterProfile#to_scorer_profile, ChatterProfileRefreshWorker,
# Twitch::GqlClient BotCheck/ViewerCard queries, AccountProfileScoring PROFILE_KEYS, plus 6 spec
# files). Twitch deprecated the `profileViewCount` GQL field; verified on staging 100% NULL
# across 144,797 chatter_profiles rows.
#
# Migration deliberately ships SEPARATELY from the code-removal PR (project precedent:
# drop_tda_philosophy_v1, drop_tih_rehab_columns, also called out in PR #208 PG iter1) so the
# Kamal rolling deploy is safe:
#
#   1. PR #208 (code-only) merged + deployed. OLD job containers keep the cached columns_hash;
#      since they don't actually reference profile_view_count anywhere anymore, they don't hit
#      the column even though they think it exists. NEW containers also don't reference it.
#   2. ≥30 min passes (Sidekiq workers cycle, no in-flight jobs reference the column).
#   3. This PR ships. Migration drops the column. No active reader/writer = no error path.
#
# Reversible: `down` recreates the column (will be all-NULL — Twitch's API is gone, no data
# is recoverable). Documented for completeness.
#
# Concurrent path NOT needed: PG `remove_column` is metadata-only via pg_attribute (O(1)),
# no btree/FK on `profile_view_count` (only `:login unique`, `:fetched_at`).
class RemoveProfileViewCountFromChatterProfiles < ActiveRecord::Migration[8.0]
  def up
    remove_column :chatter_profiles, :profile_view_count
  end

  def down
    add_column :chatter_profiles, :profile_view_count, :integer
  end
end
