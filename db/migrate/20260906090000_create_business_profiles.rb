# frozen_string_literal: true

# ONBOARD-D0 (screen 72): the brand/agency business-account application. One profile per user;
# draft → pending (submit) → approved/rejected (PO via rails runner until the admin panel,
# TASK-150.8). Approval grants a 14-day business intro Subscription (plan_type "business_intro",
# closed by the generalized expiry sweep) so a verified brand can actually use the brand surfaces.
class CreateBusinessProfiles < ActiveRecord::Migration[8.0]
  def change
    create_table :business_profiles, id: :uuid do |t|
      t.references :user, null: false, foreign_key: true, type: :uuid, index: { unique: true }
      t.string :org_type, null: false, default: "ooo", limit: 20
      t.string :company_name, limit: 160
      t.string :inn, limit: 12
      t.string :website, limit: 200
      t.string :sphere, limit: 80
      t.boolean :authority_confirmed, null: false, default: false
      t.string :status, null: false, default: "draft", limit: 20
      t.text :review_note
      t.timestamps
    end
    add_index :business_profiles, :status
  end
end
