# frozen_string_literal: true

# TASK-031: Store latest CCV in trust_index_histories for erv_count computation.
# Denormalization: avoids N+1 query to ccv_snapshots in serializer.

class AddCcvToTrustIndexHistories < ActiveRecord::Migration[8.0]
  def up
    add_column :trust_index_histories, :ccv, :integer
  end

  def down
    remove_column :trust_index_histories, :ccv
  end
end
