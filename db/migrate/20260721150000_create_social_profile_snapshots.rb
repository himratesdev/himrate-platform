# frozen_string_literal: true

# EPIC Social Analytics (SA-1) — periodic descriptive snapshots of a streamer's linked social
# platforms, keyed by Twitch login (works for ANY streamer, tracked or not — needed for brand-side
# discovery). One row per (login, platform) per refresh; the time series is what enables «рост
# подписчиков 1/3/6/12 мес» once history accumulates. Low volume (≈1 row/platform/day/streamer) →
# PostgreSQL, not ClickHouse (CH is for the high-cardinality per-post/per-minute streams).
#
# DESCRIPTIVE metrics ONLY — no fraud/накрутка verdict (PO 2026-07-21: bot-detection is Twitch-only).
# `metrics` jsonb keeps the full platform-specific blob so we can evolve without a migration per field.
class CreateSocialProfileSnapshots < ActiveRecord::Migration[8.0]
  def change
    create_table :social_profile_snapshots do |t|
      t.string :twitch_login, null: false
      t.string :platform, null: false          # telegram | youtube | vk | instagram | tiktok
      t.string :handle
      t.datetime :captured_at, null: false
      t.bigint :subscribers
      t.bigint :avg_views
      t.decimal :view_sub_ratio, precision: 6, scale: 1   # «Просматриваемость» %
      t.integer :posts_on_page
      t.jsonb :metrics, null: false, default: {}
      t.timestamps
    end

    add_index :social_profile_snapshots, %i[twitch_login platform captured_at],
              name: "idx_social_snapshots_login_platform_time"
  end
end
