# frozen_string_literal: true

# Seed helper for the ClickHouse presence layer (chat_presence_daily) used by the overlap
# products. CI runs a REAL ClickHouse (rake clickhouse:setup applies db/clickhouse/*.sql), so these
# specs exercise the actual SQL instead of a mocked client — the whole point of the layer is the
# query shape. Logins are namespaced per example by the caller to keep runs independent
# (the table has no per-test truncation; it is append-only with a TTL).
module ClickhousePresence
  module_function

  # seed("login" => %w[user1 user2], ...) — one presence row per (today, channel, user).
  def seed(sets, source: :monitored, date: Date.current)
    rows = sets.flat_map do |login, users|
      Array(users).map do |user|
        {
          date: date.to_s,
          channel_login: login.to_s,
          username: user.to_s,
          messages: 3,
          messages_monitored: source == :monitored ? 3 : 0,
          messages_farm: source == :farm ? 3 : 0
        }
      end
    end
    Clickhouse::Client.new.insert("chat_presence_daily", rows)
  end

  # Unique login prefix so parallel/repeated runs never collide on the shared table.
  def ns(name)
    "#{name}_#{SecureRandom.hex(4)}"
  end
end

RSpec.configure { |c| c.include ClickhousePresence }
