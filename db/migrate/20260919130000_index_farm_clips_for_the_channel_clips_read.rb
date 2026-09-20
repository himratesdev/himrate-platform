# frozen_string_literal: true

# GET /api/v1/channels/:login/clips takes a broadcaster's top clips by view_count. With only the
# single-column broadcaster index the pool sorts every clip ever captured for that broadcaster (the
# poller upserts up to 500 per category per run and nothing is pruned). The composite index turns
# the pool read into a bounded index scan. CONCURRENTLY: the poller writes this table all day.
#
# All THREE key columns, in the order Channels::ClipsQuery asks for them
# (view_count DESC, twitch_created_at DESC): stop at the two-column form and Postgres still has to
# sort the ties, and on a broadcaster whose clips cluster at the same view count — a fresh channel
# where most sit at 0-1 — that is the whole pool. (CR iter-2 Nit-6.)
class IndexFarmClipsForTheChannelClipsRead < ActiveRecord::Migration[8.0]
  disable_ddl_transaction!

  def change
    add_index :farm_clips, [ :broadcaster_twitch_id, :view_count, :twitch_created_at ],
              order: { view_count: :desc, twitch_created_at: :desc }, algorithm: :concurrently,
              name: "idx_farm_clips_broadcaster_views", if_not_exists: true
  end
end
