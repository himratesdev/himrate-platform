# frozen_string_literal: true

# W1 (site audit 2026-09-05): the /brands «Нужен индивидуальный объём» form was a decorative
# Pencil export — Enterprise/Managed leads had nowhere to go. Real capture table; notification
# rides TelegramAlertWorker (per-lead), status tracks manual follow-up until an admin panel
# exists (TASK-150.8).
class CreateBrandLeads < ActiveRecord::Migration[8.0]
  def change
    create_table :brand_leads, id: :uuid do |t|
      t.string :name, null: false, limit: 80
      t.string :email, null: false, limit: 255
      t.string :company, limit: 120
      t.string :budget, limit: 80
      t.text :message
      t.string :source_page, limit: 60
      t.string :status, null: false, default: "new", limit: 20
      t.timestamps
    end
    add_index :brand_leads, :created_at
    add_index :brand_leads, :email
  end
end
