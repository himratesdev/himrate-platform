# frozen_string_literal: true

# TASK-110 FR-017: JWT scope cache flag для быстрой Pundit ClipTranscriptPolicy#create? check
# без N+1 на subscriptions table per request. Default false. Recomputed on JWT issue из active
# Premium subscriptions (Auth::JwtService update separate scope).
class AddPremiumActiveToUsers < ActiveRecord::Migration[8.0]
  def change
    add_column :users, :premium_active, :boolean, null: false, default: false
    add_index :users, :premium_active, where: "premium_active = true"
  end
end
