# frozen_string_literal: true

require "rails_helper"

RSpec.describe Clickhouse::ChatRow do
  describe ".from_pg" do
    let(:full_attrs) do
      {
        stream_id: "11111111-2222-3333-4444-555555555555",
        channel_login: "shroud",
        username: "alice",
        msg_type: "privmsg",
        subscriber_status: "1",
        user_type: "mod",
        is_first_msg: false,
        returning_chatter: true,
        vip: false,
        bits_used: 100,
        display_name: "Alice",
        badge_info: "subscriber/12",
        color: "#FF0000",
        twitch_msg_id: "msg-1",
        message_text: "hi",
        emotes: "25:0-4",
        raw_tags: { "display-name" => "Alice", "subscriber" => "1" },
        timestamp: Time.utc(2026, 5, 28, 12, 0, 30, 123_000)
      }
    end

    it "maps the full canonical record (symbol keys → CH row shape)" do
      row = described_class.from_pg(full_attrs)
      expect(row[:stream_id]).to eq("11111111-2222-3333-4444-555555555555")
      expect(row[:channel_login]).to eq("shroud")
      expect(row[:msg_type]).to eq("privmsg")
      expect(row[:bits_used]).to eq(100)
      expect(row[:display_name]).to eq("Alice")
      expect(row[:twitch_msg_id]).to eq("msg-1")
    end

    it "converts booleans → UInt8 (1/0)" do
      row = described_class.from_pg(full_attrs.merge(is_first_msg: true, vip: true, returning_chatter: false))
      expect(row[:is_first_msg]).to eq(1)
      expect(row[:vip]).to eq(1)
      expect(row[:returning_chatter]).to eq(0)
    end

    it "serialises raw_tags Hash → JSON String" do
      row = described_class.from_pg(full_attrs.merge(raw_tags: { "a" => "b", "c" => 1 }))
      expect(row[:raw_tags]).to eq('{"a":"b","c":1}')
    end

    it "passes raw_tags String through unchanged (idempotent)" do
      row = described_class.from_pg(full_attrs.merge(raw_tags: '{"already":"json"}'))
      expect(row[:raw_tags]).to eq('{"already":"json"}')
    end

    it "coalesces nil raw_tags to '{}'" do
      row = described_class.from_pg(full_attrs.merge(raw_tags: nil))
      expect(row[:raw_tags]).to eq("{}")
    end

    it "formats Time → ClickHouse DateTime64(3) UTC text (millis)" do
      row = described_class.from_pg(full_attrs.merge(timestamp: Time.utc(2026, 5, 28, 12, 0, 30, 123_000)))
      expect(row[:timestamp]).to eq("2026-05-28 12:00:30.123")
    end

    it "passes timestamp String through unchanged" do
      row = described_class.from_pg(full_attrs.merge(timestamp: "2026-05-28 12:00:30.500"))
      expect(row[:timestamp]).to eq("2026-05-28 12:00:30.500")
    end

    it "preserves nil stream_id (→ CH NULL, Nullable(UUID))" do
      row = described_class.from_pg(full_attrs.merge(stream_id: nil))
      expect(row[:stream_id]).to be_nil
    end

    it "coalesces nil strings to empty (non-nullable CH columns)" do
      nilled = %i[display_name badge_info color twitch_msg_id message_text emotes subscriber_status user_type]
      row = described_class.from_pg(full_attrs.merge(nilled.to_h { |k| [ k, nil ] }))
      nilled.each { |k| expect(row[k]).to eq("") }
    end

    it "omits inserted_at (CH applies DEFAULT now())" do
      expect(described_class.from_pg(full_attrs)).not_to have_key(:inserted_at)
    end

    it "accepts string-keyed attrs (AR record#attributes) via with_indifferent_access" do
      string_attrs = full_attrs.stringify_keys
      symbol_row = described_class.from_pg(full_attrs)
      string_row = described_class.from_pg(string_attrs)
      expect(string_row).to eq(symbol_row)
    end
  end
end
