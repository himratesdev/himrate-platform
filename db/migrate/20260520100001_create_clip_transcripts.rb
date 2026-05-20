# frozen_string_literal: true

# TASK-110 FR-010..013: Clip transcripts cache (universal discipline — 1 Whisper call per unique clip_id).
# Phase-2 enrichment columns (sentiment_scores / ai_summary / highlights) nullable jsonb — populated
# by TASK-103/171/172 separate epics. whisper_cost_cents preserved as field (always 0 для local
# whisper.cpp v1.1; populated с real values при TASK-103-b OpenAI swap).
class CreateClipTranscripts < ActiveRecord::Migration[8.0]
  def change
    create_table :clip_transcripts, primary_key: :clip_id, id: :string do |t|
      # N-2 (CR): nullable until ClipTranscriptWorker fetches Helix metadata (no "pending" magic string).
      t.string :broadcaster_id
      t.jsonb :clip_metadata, null: false, default: {}
      t.string :status, null: false, default: "queued"
      t.jsonb :segments, null: false, default: []
      t.jsonb :sentiment_scores
      t.text :ai_summary
      t.jsonb :highlights
      t.string :whisper_lang
      t.integer :whisper_cost_cents, null: false, default: 0
      t.datetime :cached_at
      t.text :error_message

      t.timestamps
    end

    add_index :clip_transcripts, :broadcaster_id
    add_index :clip_transcripts, :cached_at
    add_index :clip_transcripts, :status
  end
end
