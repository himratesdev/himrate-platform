# frozen_string_literal: true

# WEB-CONSOLIDATION v3 §9 — persisted coordination groups.
#
# The detection itself lives in ClickHouse (007_coordination_events.sql + Coordination::GroupBuilder).
# Postgres holds the SNAPSHOT so the channel card can answer "is this channel in a ring?" with one
# indexed lookup instead of a multi-second columnar scan, and so a group keeps a stable id (and a
# stable "first seen") across recomputes — links to a group have to survive the next sweep.
#
# Snapshot-recompute, like the sibling cross-channel tables: each sweep rewrites the set. Identity
# is carried over by membership overlap (Coordination::Snapshot), not by row survival.
class CreateCoordinationGroups < ActiveRecord::Migration[8.0]
  def change
    create_table :coordination_groups, id: :uuid do |t|
      t.integer :member_count, null: false, default: 0
      t.integer :accounts_shared, null: false, default: 0  # accounts co-firing in >=2 members
      t.integer :events, null: false, default: 0           # their co-firing bursts in the window
      t.decimal :density, precision: 5, scale: 3           # share of member pairs that carry an edge
      t.integer :window_days, null: false
      # Corroboration = the only thing that licenses the accusatory wording on the card. It is the
      # intersection with named_bot_evidences (username × channel), the one store that already
      # carries a hard per-account verdict from the TI engine.
      t.boolean :corroborated, null: false, default: false
      t.integer :corroborated_accounts, null: false, default: 0
      t.integer :corroborated_channels, null: false, default: 0
      t.datetime :first_seen_at, null: false
      t.datetime :computed_at, null: false
      t.timestamps
    end
    add_index :coordination_groups, :computed_at
    add_index :coordination_groups, :corroborated

    create_table :coordination_group_members, id: :uuid do |t|
      t.references :coordination_group, type: :uuid, null: false, foreign_key: true, index: true
      # Nullable: a ring routinely reaches channels we do not track — dropping them would hide half
      # the evidence. `channel_login` is the identity here; `channel_id` is a convenience join.
      t.references :channel, type: :uuid, null: true, foreign_key: true
      t.string :channel_login, null: false
      t.integer :ties, null: false, default: 0     # accounts summed over this member's edges
      t.integer :accounts, null: false, default: 0 # coordinated accounts seen in THIS channel
      t.integer :events, null: false, default: 0
      t.timestamps
    end
    add_index :coordination_group_members, %i[coordination_group_id channel_login],
              unique: true, name: "idx_coord_members_unique"
    add_index :coordination_group_members, :channel_login # the card's lookup

    create_table :coordination_edges, id: :uuid do |t|
      t.references :coordination_group, type: :uuid, null: false, foreign_key: true, index: true
      t.string :a_login, null: false
      t.string :b_login, null: false
      t.integer :accounts_shared, null: false, default: 0
      t.integer :events, null: false, default: 0
      t.timestamps
    end
    add_index :coordination_edges, %i[coordination_group_id a_login b_login],
              unique: true, name: "idx_coord_edges_unique"

    # The evidence table the "Разобрать" panel renders. Bounded per group by the snapshot service —
    # we keep the strongest accounts, not the whole pool.
    create_table :coordination_accounts, id: :uuid do |t|
      t.references :coordination_group, type: :uuid, null: false, foreign_key: true, index: true
      t.string :username, null: false
      t.integer :channels_in_group, null: false, default: 0
      t.integer :events, null: false, default: 0
      t.integer :max_concurrent, null: false, default: 0
      t.decimal :median_interval_sec, precision: 8, scale: 1 # posting rhythm, seconds
      t.decimal :interval_cv, precision: 6, scale: 3         # ~0 = metronome
      t.boolean :named_bot, null: false, default: false      # already flagged by the TI engine
      t.datetime :last_at
      t.timestamps
    end
    add_index :coordination_accounts, %i[coordination_group_id username],
              unique: true, name: "idx_coord_accounts_unique"
  end
end
