# frozen_string_literal: true

module Clickhouse
  # TASK-251.14c (post-PR-1e-A): single source of truth for the parsed-record → ClickHouse
  # chat_messages row mapping. Used by both code paths so they produce byte-identical rows:
  #   • ChatMessageWorker#write_to_clickhouse (live ingest, primary writer post-cutover) —
  #     symbol-keyed hash from parse_message;
  #   • Clickhouse::ChatBackfill (historical, pre-PR-1e-B drop) — string-keyed hash from AR
  #     record#attributes (only meaningful while PG chat_messages table still exists).
  # Accepts either via with_indifferent_access. Coalesces nils to non-nullable column defaults,
  # booleans → UInt8, raw_tags Hash → JSON String, Time → ClickHouse DateTime64(3) text. stream_id
  # stays nil → CH NULL (Nullable(UUID)); inserted_at is omitted so CH applies its DEFAULT now().
  module ChatRow
    module_function

    def from_pg(attrs)
      a = attrs.with_indifferent_access
      {
        stream_id: a[:stream_id],
        channel_login: a[:channel_login].to_s,
        username: a[:username].to_s,
        msg_type: a[:msg_type].to_s,
        subscriber_status: a[:subscriber_status].to_s,
        user_type: a[:user_type].to_s,
        is_first_msg: a[:is_first_msg] ? 1 : 0,
        returning_chatter: a[:returning_chatter] ? 1 : 0,
        vip: a[:vip] ? 1 : 0,
        bits_used: a[:bits_used].to_i,
        display_name: a[:display_name].to_s,
        badge_info: a[:badge_info].to_s,
        color: a[:color].to_s,
        twitch_msg_id: a[:twitch_msg_id].to_s,
        message_text: a[:message_text].to_s,
        emotes: a[:emotes].to_s,
        raw_tags: serialize_raw_tags(a[:raw_tags]),
        timestamp: format_timestamp(a[:timestamp])
      }
    end

    def serialize_raw_tags(value)
      return value if value.is_a?(String)

      JSON.generate(value || {})
    end
    private_class_method :serialize_raw_tags

    def format_timestamp(value)
      return value if value.is_a?(String)

      value.utc.strftime("%Y-%m-%d %H:%M:%S.%3N")
    end
    private_class_method :format_timestamp
  end
end
