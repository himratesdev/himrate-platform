# frozen_string_literal: true

# TASK-110 FR-014: Per-user clip transcript request counter для Pundit Free 10/мес gate.
# UNIQUE (user_id, clip_transcript_id) = idempotency (same user, same clip = 1 row).
class CreateClipTranscriptRequests < ActiveRecord::Migration[8.0]
  def change
    create_table :clip_transcript_requests do |t|
      t.references :user, null: false, foreign_key: true, type: :uuid
      t.string :clip_transcript_id, null: false
      t.datetime :requested_at, null: false

      t.timestamps
    end

    add_index :clip_transcript_requests, %i[user_id clip_transcript_id], unique: true
    add_index :clip_transcript_requests, %i[user_id requested_at]
    add_foreign_key :clip_transcript_requests, :clip_transcripts,
                    column: :clip_transcript_id, primary_key: :clip_id
  end
end
