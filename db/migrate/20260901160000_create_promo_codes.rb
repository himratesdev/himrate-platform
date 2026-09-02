# frozen_string_literal: true

# TASK-H8 (Day-0 slice, TASK-K3 Soft Launch): promo codes granting tier access without billing.
# Full canonical schema (6 kinds per PRICING v4.2 §"Promocodes system") — the billing-era flows
# (card trials, auto-prompt upgrade) plug into these same tables later, no rework.
class CreatePromoCodes < ActiveRecord::Migration[8.0]
  def change
    create_table :promo_codes, id: :uuid do |t|
      t.string :code, null: false, limit: 40
      t.string :kind, null: false, limit: 24
      t.string :grants_tier, null: false, limit: 20
      t.integer :duration_days             # nil = lifetime grant
      t.integer :max_redemptions           # nil = unlimited
      t.integer :redemptions_count, null: false, default: 0
      t.datetime :expires_at               # code redeemable-until (nil = no deadline)
      t.boolean :active, null: false, default: true
      t.string :note, limit: 200           # who/why this batch was minted
      t.timestamps
    end
    add_index :promo_codes, "UPPER(code)", unique: true, name: "index_promo_codes_on_upper_code"

    create_table :promo_redemptions, id: :uuid do |t|
      t.references :promo_code, null: false, foreign_key: true, type: :uuid
      t.references :user, null: false, foreign_key: true, type: :uuid
      t.string :granted_tier, null: false, limit: 20
      t.datetime :grant_expires_at         # nil = lifetime
      t.timestamps
    end
    add_index :promo_redemptions, %i[promo_code_id user_id], unique: true
  end
end
