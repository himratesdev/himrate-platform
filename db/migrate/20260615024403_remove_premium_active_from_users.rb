# frozen_string_literal: true

# 2-phase column drop (after PR #302 removed the last code that READ this column).
#
# `users.premium_active` was added by 20260520100005 (PR #158) as a JWT-scope cache flag
# for ClipTranscriptPolicy#create?, but it was NEVER written by any code (always defaulted
# false) and — after PR #302 made the paywall derive from `user.tier` via
# ApplicationPolicy#premium? — is NEVER read either. Drop the orphaned column + its index.
#
# Reversible: `down` recreates the column AND partial index exactly as 20260520100005 defined
# them (boolean, null: false, default: false; partial index WHERE premium_active = true).
class RemovePremiumActiveFromUsers < ActiveRecord::Migration[8.0]
  def up
    remove_column :users, :premium_active
  end

  def down
    add_column :users, :premium_active, :boolean, null: false, default: false
    add_index :users, :premium_active, where: "premium_active = true"
  end
end
