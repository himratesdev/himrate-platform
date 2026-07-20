# frozen_string_literal: true

# T1-074 pre-flip follow-up (PR3b CR): the delta-write evidence guard
# (V2::Persistence#new_evidence_chatters) reads `WHERE stream_id = ? DISTINCT username` on every
# ~30s c_hard compute — without this index that is a sequential scan growing with the table.
class AddStreamUsernameIndexToNamedBotEvidences < ActiveRecord::Migration[8.0]
  disable_ddl_transaction!

  def change
    add_index :named_bot_evidences, %i[stream_id username],
      name: "idx_named_bot_evidence_stream_username", algorithm: :concurrently, if_not_exists: true
  end
end
