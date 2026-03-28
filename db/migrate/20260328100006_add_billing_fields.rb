# frozen_string_literal: true

# TASK-017: Provider-agnostic billing fields on subscriptions + price/TTL on pdf_reports.

class AddBillingFields < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    add_column :subscriptions, :provider_subscription_id, :string, limit: 255
    add_column :subscriptions, :billing_period_end, :datetime

    add_index :subscriptions, :provider_subscription_id, unique: true,
      name: "idx_subscriptions_provider_sub_id", algorithm: :concurrently, if_not_exists: true

    add_column :pdf_reports, :price_charged, :decimal, precision: 10, scale: 2
    add_column :pdf_reports, :expires_at, :datetime
  end

  def down
    remove_index :subscriptions, name: "idx_subscriptions_provider_sub_id", if_exists: true
    remove_column :subscriptions, :provider_subscription_id
    remove_column :subscriptions, :billing_period_end

    remove_column :pdf_reports, :price_charged
    remove_column :pdf_reports, :expires_at
  end
end
