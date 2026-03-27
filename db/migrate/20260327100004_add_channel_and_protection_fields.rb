# frozen_string_literal: true

# TASK-016: Channel account age (Signal #1) + Protection config fields (Signal #6 CPS).

class AddChannelAndProtectionFields < ActiveRecord::Migration[8.1]
  def up
    add_column :channels, :twitch_account_created_at, :datetime

    change_table :channel_protection_configs, bulk: true do |t|
      t.integer :minimum_account_age_minutes
      t.boolean :restrict_first_time_chatters, null: false, default: false
    end
  end

  def down
    remove_column :channels, :twitch_account_created_at

    change_table :channel_protection_configs, bulk: true do |t|
      t.remove :minimum_account_age_minutes
      t.remove :restrict_first_time_chatters
    end
  end
end
