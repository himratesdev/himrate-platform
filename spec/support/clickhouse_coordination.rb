# frozen_string_literal: true

# Seed helpers for the coordination layer. CI runs a REAL ClickHouse (rake clickhouse:setup applies
# db/clickhouse/*.sql), so these specs exercise the actual SQL — which is the whole point: the
# finding IS the query. Logins/usernames are namespaced per example (`ns`) because the tables are
# append-only with a TTL and have no per-test truncation.
module ClickhouseCoordination
  module_function

  # Pre-aggregated rows, for the read side (accounts / channel_pairs / groups).
  #   seed_coordination(hour, "user1" => { channels: %w[a b c], events: 4, max_concurrent: 3 })
  def seed_coordination(hour, accounts)
    rows = accounts.map do |username, attrs|
      {
        hour: hour.utc.strftime("%Y-%m-%d %H:00:00"),
        username: username.to_s,
        events: attrs.fetch(:events, 2),
        max_concurrent: attrs.fetch(:max_concurrent, attrs[:channels].size),
        channels: Array(attrs[:channels]).map(&:to_s),
        last_at: (attrs[:last_at] || hour).utc.strftime("%Y-%m-%d %H:%M:%S")
      }
    end
    Clickhouse::Client.new.insert("coordination_events", rows)
  end

  # Raw chat, for the collector. Writes one message per (channel, account) at `at` so the burst
  # lands in a single 5-second bucket.
  def seed_chat_burst(at, channels, usernames)
    rows = channels.flat_map do |login|
      usernames.map do |user|
        {
          channel_login: login.to_s,
          username: user.to_s,
          msg_type: "privmsg",
          subscriber_status: "none",
          user_type: "",
          is_first_msg: 0,
          returning_chatter: 0,
          vip: 0,
          bits_used: 0,
          display_name: user.to_s,
          badge_info: "",
          color: "",
          twitch_msg_id: SecureRandom.uuid,
          message_text: "gg",
          emotes: "",
          raw_tags: "",
          timestamp: at.utc.strftime("%Y-%m-%d %H:%M:%S.%L")
        }
      end
    end
    Clickhouse::Client.new.insert("chat_messages", rows)
  end
end

RSpec.configure { |c| c.include ClickhouseCoordination }
