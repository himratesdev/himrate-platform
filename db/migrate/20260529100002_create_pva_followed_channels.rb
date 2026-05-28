# frozen_string_literal: true

# TASK-113 Δ-1 Wave 1 source #1 (FR-016): viewer's followed channels list, populated from Helix
# GET /channels/followed at enrollment time. Per-user followed list (denormalized from Channel —
# avoids cross-user contamination, mirrors PVA-private storage pattern of pva_view_rollups +
# channel_tenure + pva_chat_activities).
class CreatePvaFollowedChannels < ActiveRecord::Migration[8.0]
  def up
    execute(<<~SQL)
      CREATE TABLE pva_followed_channels (
        id uuid NOT NULL DEFAULT gen_random_uuid(),
        user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
        twitch_channel_id varchar(30) NOT NULL,
        twitch_login varchar(50),
        display_name varchar(100),
        avatar_url varchar(500),
        primary_color_hex varchar(7),
        followed_at timestamp(6) without time zone NOT NULL,
        created_at timestamp(6) without time zone NOT NULL DEFAULT now(),
        updated_at timestamp(6) without time zone NOT NULL DEFAULT now(),
        PRIMARY KEY (id)
      );
    SQL

    add_index :pva_followed_channels, %i[user_id twitch_channel_id], unique: true,
      name: "idx_pva_followed_channels_user_channel"
    add_index :pva_followed_channels, %i[user_id followed_at],
      name: "idx_pva_followed_channels_user_followed_at"
  end

  def down
    drop_table :pva_followed_channels
  end
end
