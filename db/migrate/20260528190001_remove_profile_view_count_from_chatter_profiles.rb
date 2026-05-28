# frozen_string_literal: true

# TASK-251.20: Drop dead `profile_view_count` column from `chatter_profiles`.
#
# Twitch deprecated the `profileViewCount` GQL field — verified on staging:
# 100% NULL across 144,797 chatter_profiles rows (zero not-null values). The
# bot-detection signal `profile_view_zero` that depended on this column never
# fired (predicate `profile[:profile_view_count]&.zero?` is always falsy on nil).
#
# Reversible: down recreates the column (will be all-NULL again — Twitch's API
# is gone; no data is recoverable). Documented for completeness.
#
# Concurrent path NOT needed: column is small (integer, NULL on 100% rows),
# `remove_column` is fast on PG when no btree/non-default constraints exist.
class RemoveProfileViewCountFromChatterProfiles < ActiveRecord::Migration[8.0]
  def up
    remove_column :chatter_profiles, :profile_view_count
  end

  def down
    add_column :chatter_profiles, :profile_view_count, :integer
  end
end
