# frozen_string_literal: true

# TASK-113 Δ-1 Wave 1 (FR-016 BRD/SRS/ADR v3.0): durable state-table для cold-start enrollment
# backfill orchestrator. Mediates с Redis hash `pva:backfill:{user_id}` (fast read для frontend
# polling, 24h TTL) + durable persistence (state survives Redis flush).
#
# Per ADR v3.0 §4 (Variant B: 5 separate workers + Redis state aggregation + frontend polling):
# - 1 row per user (unique user_id)
# - sources jsonb { source_1: {status, started_at, completed_at, rows_affected, error_class},
#                   source_2: {...}, source_3: {...}, source_4: {...}, source_5: {...} }
# - overall_status: pending|in_progress|partial|done|partial_timeout|failed
# - completed_at NULL пока not all sources terminal
# - failed_sources text[] — quick lookup для retry UX
# - Idempotency (BR-015): re-enrollment skip if last_backfilled_at < 30d (queried via oauth_linked_at + completed_at)
#
# Wave 1 sources active: #1 Helix /channels/followed · #2 anon GQL ChannelShell · #5 Apollo cache walk
# (deferred Wave 2: #3 CH chat_messages backfill; deferred optional: #4 GQL self-subs replay).
class CreatePvaEnrollmentBackfillState < ActiveRecord::Migration[8.0]
  def up
    execute(<<~SQL)
      CREATE TABLE pva_enrollment_backfill_state (
        id uuid NOT NULL DEFAULT gen_random_uuid(),
        user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
        oauth_linked_at timestamp(6) without time zone NOT NULL,
        sources jsonb NOT NULL DEFAULT '{}',
        overall_status varchar(32) NOT NULL DEFAULT 'pending',
        completed_at timestamp(6) without time zone,
        failed_sources text[] NOT NULL DEFAULT '{}',
        created_at timestamp(6) without time zone NOT NULL DEFAULT now(),
        updated_at timestamp(6) without time zone NOT NULL DEFAULT now(),
        PRIMARY KEY (id)
      );
    SQL

    add_index :pva_enrollment_backfill_state, :user_id, unique: true,
      name: "idx_pva_enrollment_backfill_state_user_id"
    # CR iter-2 N1 acknowledgement: completed_at idx dropped (no query filters by it alone).
    # Stuck sweep queries `(overall_status, oauth_linked_at)` per stuck scope.
    add_index :pva_enrollment_backfill_state, %i[overall_status oauth_linked_at],
      name: "idx_pva_enrollment_backfill_state_status_linked"
  end

  def down
    drop_table :pva_enrollment_backfill_state
  end
end
