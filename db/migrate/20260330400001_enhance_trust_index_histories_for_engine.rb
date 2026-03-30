# frozen_string_literal: true

# TASK-029: Add classification, cold_start_status, erv_percent, rehabilitation columns
# to trust_index_histories for Trust Index Engine output.

class EnhanceTrustIndexHistoriesForEngine < ActiveRecord::Migration[8.0]
  disable_ddl_transaction!

  def up
    add_column :trust_index_histories, :classification, :string, limit: 20
    add_column :trust_index_histories, :cold_start_status, :string, limit: 20
    add_column :trust_index_histories, :erv_percent, :decimal, precision: 5, scale: 2
    add_column :trust_index_histories, :rehabilitation_penalty, :decimal, precision: 5, scale: 2, default: 0
    add_column :trust_index_histories, :rehabilitation_bonus, :decimal, precision: 5, scale: 2, default: 0
  end

  def down
    remove_column :trust_index_histories, :rehabilitation_bonus
    remove_column :trust_index_histories, :rehabilitation_penalty
    remove_column :trust_index_histories, :erv_percent
    remove_column :trust_index_histories, :cold_start_status
    remove_column :trust_index_histories, :classification
  end
end
