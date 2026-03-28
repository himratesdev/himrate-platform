# frozen_string_literal: true

# TASK-016: Fields needed for bot scoring profile completeness check.
# Bot scorer uses these to evaluate Twitch account legitimacy.

class AddBotScoringFields < ActiveRecord::Migration[8.1]
  def up
    change_table :user_accounts, bulk: true do |t|
      t.integer :profile_view_count
      t.integer :videos_total_count
      t.datetime :last_broadcast_at
      t.text :description
      t.text :banner_image_url
    end
  end

  def down
    change_table :user_accounts, bulk: true do |t|
      t.remove :profile_view_count
      t.remove :videos_total_count
      t.remove :last_broadcast_at
      t.remove :description
      t.remove :banner_image_url
    end
  end
end
