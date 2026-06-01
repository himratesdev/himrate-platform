# frozen_string_literal: true

# 2026-06-01 fix companion to Stream model cross_channel_presences cascade.
# Original migration (20260328100003_create_cross_channel_presences) explicitly set
# `index: false` on the stream reference + only a composite (channel_id, stream_id) index.
# Postgres cannot use a composite for a trailing-column-only predicate, so the cascade
# query `... WHERE stream_id = ?` (fired per Stream.destroy by dependent: :nullify) was
# a sequential scan over a chatters-scale table. Phase 2 fuse cleanup would have re-scanned
# the CCP table 600+ times.
#
# Concurrent + if_not_exists for reversibility + idempotency on staging/prod replay.
class AddStreamIdIndexToCrossChannelPresences < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def change
    add_index :cross_channel_presences, :stream_id, algorithm: :concurrently, if_not_exists: true
  end
end
