# frozen_string_literal: true

# LK-BACKEND Wave 1a: "notify me when the cabinet opens" captures from the flag-off state
# (screen 71, saas_lk_live OFF). Stores emails to notify at ЛК launch. Dedup by normalized email.
class CreateNotifyRequests < ActiveRecord::Migration[8.0]
  def change
    create_table :notify_requests, id: :uuid do |t|
      t.string :email, limit: 255, null: false
      t.references :user, type: :uuid, foreign_key: true, null: true
      t.string :source, limit: 32, null: false, default: "lk_launch"
      t.datetime :notified_at

      t.timestamps
    end

    add_index :notify_requests, :email, unique: true
    add_index :notify_requests, :notified_at
  end
end
