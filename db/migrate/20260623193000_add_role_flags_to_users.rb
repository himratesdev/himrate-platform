# frozen_string_literal: true

# T1-060 FR-1 (phase-1): accumulating role flags replacing the mutually-exclusive
# users.role scalar. viewer = implicit (any registered user); is_streamer / is_brand
# accumulate by action and can be true simultaneously. The role scalar stays
# write-through-synced this phase and is dropped in the T1-060 phase-2 follow-up TASK
# (ignored_columns + remove_column), per the premium_active precedent (#158 → #311 drop).
#
# Partial indexes (WHERE flag = true) mirror 20260520100005_add_premium_active_to_users.
# add_column null:false default:false = PG11+ fast-default (no table rewrite); users is a
# bounded OLTP table so the in-transaction backfill is acceptable (see ADR DEC-7).
class AddRoleFlagsToUsers < ActiveRecord::Migration[8.0]
  def up
    add_column :users, :is_streamer, :boolean, null: false, default: false
    add_column :users, :is_brand, :boolean, null: false, default: false
    add_index :users, :is_streamer, where: "is_streamer = true"
    add_index :users, :is_brand, where: "is_brand = true"

    Users::RoleFlagBackfill.run!
  end

  def down
    remove_column :users, :is_brand
    remove_column :users, :is_streamer
  end
end
