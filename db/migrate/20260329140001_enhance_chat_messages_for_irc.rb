# frozen_string_literal: true

# TASK-024: Add IRC-specific fields to chat_messages for full PRIVMSG/USERNOTICE/ROOMSTATE/CLEARCHAT parsing.
# Existing columns: id(uuid), stream_id(uuid FK), username(255), message_text(text),
#   timestamp(datetime), subscriber_status(10), is_first_msg(bool), user_type(10), bits_used(int), entropy(decimal)
# New columns: channel_login, msg_type, display_name, badge_info, returning_chatter, vip, color, emotes, twitch_msg_id, raw_tags
# stream_id made nullable: IRC messages may arrive before stream_session is created in DB.

class EnhanceChatMessagesForIrc < ActiveRecord::Migration[8.0]
  disable_ddl_transaction!

  def up
    # New columns
    add_column :chat_messages, :channel_login, :string, limit: 255
    add_column :chat_messages, :msg_type, :string, limit: 20, default: "privmsg", null: false
    add_column :chat_messages, :display_name, :string, limit: 255
    add_column :chat_messages, :badge_info, :string, limit: 255
    add_column :chat_messages, :returning_chatter, :boolean, null: false, default: false
    add_column :chat_messages, :vip, :boolean, null: false, default: false
    add_column :chat_messages, :color, :string, limit: 7
    add_column :chat_messages, :emotes, :text
    add_column :chat_messages, :twitch_msg_id, :string, limit: 255
    add_column :chat_messages, :raw_tags, :jsonb, null: false, default: {}

    # Make stream_id nullable (IRC messages may arrive before stream record exists)
    change_column_null :chat_messages, :stream_id, true

    # Indexes (concurrent to avoid locks on populated tables)
    add_index :chat_messages, :channel_login, name: "idx_chat_messages_channel_login",
      algorithm: :concurrently, if_not_exists: true
    add_index :chat_messages, :msg_type, name: "idx_chat_messages_msg_type",
      algorithm: :concurrently, if_not_exists: true
    add_index :chat_messages, %i[channel_login timestamp], name: "idx_chat_messages_channel_time",
      algorithm: :concurrently, if_not_exists: true
  end

  def down
    remove_index :chat_messages, name: "idx_chat_messages_channel_time", if_exists: true
    remove_index :chat_messages, name: "idx_chat_messages_msg_type", if_exists: true
    remove_index :chat_messages, name: "idx_chat_messages_channel_login", if_exists: true

    change_column_null :chat_messages, :stream_id, false

    remove_column :chat_messages, :raw_tags
    remove_column :chat_messages, :twitch_msg_id
    remove_column :chat_messages, :emotes
    remove_column :chat_messages, :color
    remove_column :chat_messages, :vip
    remove_column :chat_messages, :returning_chatter
    remove_column :chat_messages, :badge_info
    remove_column :chat_messages, :display_name
    remove_column :chat_messages, :msg_type
    remove_column :chat_messages, :channel_login
  end
end
