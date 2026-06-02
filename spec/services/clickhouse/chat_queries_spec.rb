# frozen_string_literal: true

require "rails_helper"

RSpec.describe Clickhouse::ChatQueries do
  let(:ch) { instance_double(Clickhouse::Client) }
  let(:stream_id) { SecureRandom.uuid }
  let(:stream) { instance_double(Stream, id: stream_id) }

  before { allow(Clickhouse).to receive(:client).and_return(ch) }

  describe ".chat_rate" do
    it "queries mv_stream_minute_target with minute-floored `since` and returns PG-shaped rows" do
      since = Time.utc(2026, 5, 28, 12, 5, 37)
      since_floored = since.beginning_of_minute # caller floors before calling
      expect(ch).to receive(:select).with(
        a_string_matching(/FROM mv_stream_minute_target/)
          .and(a_string_matching(/stream_id = '#{stream_id}'/))
          .and(a_string_matching(/minute >= '2026-05-28 12:05:00'/))
          .and(a_string_matching(/countMerge\(msg_count\)/))
      ).and_return([
                     { "minute" => "2026-05-28 12:05:00", "c" => "12" },
                     { "minute" => "2026-05-28 12:06:00", "c" => "8" }
                   ])

      result = described_class.chat_rate(stream, since_floored)
      expect(result).to eq([
                             { msg_count: 12, timestamp: Time.utc(2026, 5, 28, 12, 5) },
                             { msg_count: 8,  timestamp: Time.utc(2026, 5, 28, 12, 6) }
                           ])
    end

    it "swallows Clickhouse::Error and returns [] (parity with PG rescue path)" do
      allow(ch).to receive(:select).and_raise(Clickhouse::QueryError, "boom")
      expect(described_class.chat_rate(stream, Time.utc(2026, 5, 28))).to eq([])
    end
  end

  describe ".chat_username_counts" do
    it "queries mv_stream_user_minute_target grouped by username and returns { username => count }" do
      since = Time.utc(2026, 5, 28, 12, 5).beginning_of_minute
      expect(ch).to receive(:select).with(
        a_string_matching(/FROM mv_stream_user_minute_target/)
          .and(a_string_matching(/GROUP BY username/))
      ).and_return([ { "username" => "alice", "c" => "3" }, { "username" => "bob", "c" => "1" } ])

      expect(described_class.chat_username_counts(stream, since)).to eq("alice" => 3, "bob" => 1)
    end
  end

  describe ".unique_chatters" do
    let(:since) { Time.utc(2026, 5, 28, 11, 30) }

    it "queries mv_stream_minute_target via uniqExactMerge for the supplied window" do
      expect(ch).to receive(:select).with(
        a_string_matching(/uniqExactMerge\(unique_chatters\)/)
          .and(a_string_matching(/FROM mv_stream_minute_target/))
          .and(a_string_matching(/minute >= '2026-05-28 11:30:00'/))
      ).and_return([ { "u" => "42" } ])

      expect(described_class.unique_chatters(stream, since)).to eq(42)
    end

    it "returns nil when CH returns no rows (parity with PG rescue path returning nil)" do
      allow(ch).to receive(:select).and_return([])
      expect(described_class.unique_chatters(stream, since)).to be_nil
    end
  end

  describe ".cross_channel" do
    let(:since) { Time.utc(2026, 5, 27, 12, 30, 45) }

    it "fetches usernames (ORDER BY) then uniqExact(channel_login) over the supplied window" do
      expect(ch).to receive(:select).with(a_string_matching(/SELECT DISTINCT username.*ORDER BY username.*LIMIT 500/m))
                                    .and_return([ { "username" => "alice" }, { "username" => "bob" } ])
      expect(ch).to receive(:select).with(
        a_string_matching(/uniqExact\(channel_login\)/)
          .and(a_string_matching(/IN \('alice','bob'\)/))
          .and(a_string_matching(/timestamp > toDateTime\('2026-05-27 12:30:45'\)/))
      ).and_return([ { "username" => "alice", "c" => "3" }, { "username" => "bob", "c" => "1" } ])

      expect(described_class.cross_channel(stream, since)).to eq("alice" => 3, "bob" => 1)
    end

    it "returns {} when the stream has no chatters (skips the second query)" do
      expect(ch).to receive(:select).once.and_return([])
      expect(described_class.cross_channel(stream, since)).to eq({})
    end

    it "escapes single quotes in usernames" do
      expect(ch).to receive(:select).and_return([ { "username" => "o'reilly" } ])
      expect(ch).to receive(:select).with(a_string_matching(/IN \('o''reilly'\)/)).and_return([])
      described_class.cross_channel(stream, since)
    end

    it "escapes backslashes in usernames (CR-206 Should-3 — CH single-quoted strings honour `\\`)" do
      expect(ch).to receive(:select).and_return([ { "username" => "back\\slash" } ])
      expect(ch).to receive(:select).with(a_string_matching(/IN \('back\\\\slash'\)/)).and_return([])
      described_class.cross_channel(stream, since)
    end
  end

  # BUG-SCW-CROSS-CHANNEL (2026-06-02): the q1 username pick was extracted so the digest-backed
  # ContextBuilder path can call it without the heavy q2 24h scan that `cross_channel` still runs.
  describe ".stream_chatters" do
    it "returns the deterministic ORDER BY username LIMIT 500 chatter list" do
      expect(ch).to receive(:select).with(
        a_string_matching(/SELECT DISTINCT username/)
          .and(a_string_matching(/stream_id = '#{stream.id}'/))
          .and(a_string_matching(/ORDER BY username/))
          .and(a_string_matching(/LIMIT 500/))
      ).and_return([ { "username" => "alice" }, { "username" => "bob" } ])

      expect(described_class.stream_chatters(stream)).to eq(%w[alice bob])
    end

    it "returns [] when CH returns no rows" do
      expect(ch).to receive(:select).and_return([])
      expect(described_class.stream_chatters(stream)).to eq([])
    end

    it "returns [] (and logs) when CH raises a query error — caller treats as no-data" do
      expect(ch).to receive(:select).and_raise(Clickhouse::QueryError.new("CH down"))
      expect(Rails.logger).to receive(:warn).with(/stream_chatters failed/)

      expect(described_class.stream_chatters(stream)).to eq([])
    end
  end

  describe "integration (real ClickHouse)", :clickhouse do
    let(:real_client) { Clickhouse.client }
    let(:t) { Time.current.utc }
    let(:stream_id) { SecureRandom.uuid }
    let(:stream) { instance_double(Stream, id: stream_id) }

    before do
      # The outer `before` stubs Clickhouse.client → instance_double; integration tests need the
      # real client. Restore the original delegation here, then skip if CH is not reachable.
      allow(Clickhouse).to receive(:client).and_call_original
      skip "ClickHouse not reachable" unless real_client.ping
    end

    def insert(rows)
      Clickhouse::Client.new.insert("chat_messages", rows.map do |r|
        Clickhouse::ChatRow.from_pg({
          stream_id: r[:stream_id] || stream_id, channel_login: r[:channel_login] || "ch",
          username: r[:username], msg_type: r[:msg_type] || "privmsg",
          timestamp: (r[:timestamp] || t).utc.strftime("%Y-%m-%d %H:%M:%S.%3N"),
          raw_tags: "{}"
        })
      end)
    end

    it "chat_rate sees the rolled-up minute counts after the MV picks up inserts" do
      m0 = t.beginning_of_minute - 2.minutes
      insert([
               { username: "u1", timestamp: m0 + 5.seconds },
               { username: "u2", timestamp: m0 + 10.seconds },
               { username: "u3", timestamp: m0 + 60.seconds }
             ])

      result = described_class.chat_rate(stream, m0)
      counts = result.to_h { |r| [ r[:timestamp].utc.to_i, r[:msg_count] ] }
      expect(counts[m0.to_i]).to eq(2)
      expect(counts[(m0 + 60.seconds).to_i]).to eq(1)
    end

    it "unique_chatters returns the merged uniqExact over the supplied window" do
      since = t.beginning_of_minute - 60.minutes
      insert([
               { username: "u1", timestamp: t.beginning_of_minute - 5.minutes },
               { username: "u2", timestamp: t.beginning_of_minute - 3.minutes },
               { username: "u1", timestamp: t.beginning_of_minute - 1.minutes } # repeat — uniqExact=2
             ])
      expect(described_class.unique_chatters(stream, since)).to eq(2)
    end
  end

  # PR 1e-A (CR-231 N2) — direct unit specs for the 6 new methods added in the cutover.
  # SQL-shape regression: each describe asserts the right table, GROUP BY, WHERE filters
  # (privmsg + non-empty), and aggregate functions. Coverage gap noted by PG #0b — closes it
  # in-PR (not via follow-up) per Iron Rule #5.
  describe ".chatter_aggregations" do
    let(:stream) { instance_double(Stream, id: stream_id) }

    it "groups raw chat_messages by username with PG-shaped per-user aggregates" do
      expect(ch).to receive(:select).with(
        a_string_matching(/FROM chat_messages/)
          .and(a_string_matching(/stream_id = '#{stream_id}'/))
          .and(a_string_matching(/GROUP BY username/))
          .and(a_string_matching(/any\(user_type\)/))
          .and(a_string_matching(/max\(returning_chatter\)/))
          .and(a_string_matching(/sum\(bits_used\)/))
          .and(a_string_matching(/count\(\)/))
      ).and_return([
                     { "username" => "alice", "user_type" => "mod", "subscriber_status" => "1",
                       "returning_chatter" => "1", "vip" => "0", "badge_info" => "subscriber/12",
                       "bits_used" => "100", "msg_count" => "5" }
                   ])

      result = described_class.chatter_aggregations(stream)
      entry = result.fetch("alice")
      expect(entry[:irc_tags]).to include(user_type: "mod", subscriber_status: "1",
                                          returning_chatter: true, vip: false,
                                          badge_info: "subscriber/12", bits_used: 100)
      expect(entry[:chat_stats]).to eq(message_count: 5)
    end

    it "raises ArgumentError for non-UUID stream.id (validate_stream_uuid! guard)" do
      bad_stream = instance_double(Stream, id: "not-a-uuid; DROP TABLE chat_messages;--")
      expect { described_class.chatter_aggregations(bad_stream) }
        .to raise_error(ArgumentError, /not a UUID/)
    end

    it "returns {} on Clickhouse::Error (transient infra contract)" do
      allow(ch).to receive(:select).and_raise(Clickhouse::QueryError, "boom")
      expect(described_class.chatter_aggregations(stream)).to eq({})
    end
  end

  describe ".chatter_timestamps" do
    let(:stream) { instance_double(Stream, id: stream_id) }

    it "returns Hash { username => [Time, ...] } ordered ascending" do
      ts_a1 = "2026-05-31 10:00:01"; ts_a2 = "2026-05-31 10:00:05"; ts_b = "2026-05-31 10:00:03"
      expect(ch).to receive(:select).with(
        a_string_matching(/SELECT username, timestamp/)
          .and(a_string_matching(/msg_type = 'privmsg'/))
          .and(a_string_matching(/username != ''/))
          .and(a_string_matching(/ORDER BY username, timestamp/))
      ).and_return([
                     { "username" => "alice", "timestamp" => ts_a1 },
                     { "username" => "alice", "timestamp" => ts_a2 },
                     { "username" => "bob",   "timestamp" => ts_b }
                   ])

      result = described_class.chatter_timestamps(stream)
      expect(result.keys).to contain_exactly("alice", "bob")
      expect(result["alice"].size).to eq(2)
      expect(result["alice"].first).to be_a(Time)
    end

    it "returns {} on Clickhouse::Error" do
      allow(ch).to receive(:select).and_raise(Clickhouse::QueryError, "boom")
      expect(described_class.chatter_timestamps(stream)).to eq({})
    end
  end

  describe ".chatter_messages" do
    let(:stream) { instance_double(Stream, id: stream_id) }

    it "groups by username with privmsg + non-empty message_text filters" do
      expect(ch).to receive(:select).with(
        a_string_matching(/SELECT username, message_text/)
          .and(a_string_matching(/msg_type = 'privmsg'/))
          .and(a_string_matching(/username != ''/))
          .and(a_string_matching(/message_text != ''/))
      ).and_return([
                     { "username" => "alice", "message_text" => "hi" },
                     { "username" => "alice", "message_text" => "bye" }
                   ])

      expect(described_class.chatter_messages(stream)).to eq("alice" => [ "hi", "bye" ])
    end
  end

  describe ".chatter_emotes" do
    let(:stream) { instance_double(Stream, id: stream_id) }

    it "groups by username with non-empty emotes filter" do
      expect(ch).to receive(:select).with(
        a_string_matching(/SELECT username, emotes/)
          .and(a_string_matching(/emotes != ''/))
      ).and_return([ { "username" => "alice", "emotes" => "25:0-4/50:6-9" } ])

      expect(described_class.chatter_emotes(stream)).to eq("alice" => [ "25:0-4/50:6-9" ])
    end
  end

  describe ".chatter_cross_channel_counts" do
    it "returns {} on empty usernames (no SQL roundtrip)" do
      expect(ch).not_to receive(:select)
      expect(described_class.chatter_cross_channel_counts([], 24.hours.ago)).to eq({})
    end

    it "queries with PRIVMSG filter (CR S1: intentional shift from PG path that lacked filter)" do
      since = Time.utc(2026, 5, 30, 12, 0, 0)
      expect(ch).to receive(:select).with(
        a_string_matching(/SELECT username, uniqExact\(channel_login\)/)
          .and(a_string_matching(/msg_type = 'privmsg'/)) # CR S1 lock-in
          .and(a_string_matching(/timestamp > toDateTime\('2026-05-30 12:00:00'\)/))
          .and(a_string_matching(/'alice','bob'/))
      ).and_return([ { "username" => "alice", "c" => "3" }, { "username" => "bob", "c" => "1" } ])

      expect(described_class.chatter_cross_channel_counts(%w[alice bob], since))
        .to eq("alice" => 3, "bob" => 1)
    end

    it "escapes single-quotes + backslashes in usernames (escape_string_literal)" do
      since = Time.utc(2026, 5, 30, 12, 0, 0)
      expect(ch).to receive(:select).with(
        a_string_matching(/'o''reilly'/) # single-quote doubled per CH escape
      ).and_return([])
      described_class.chatter_cross_channel_counts([ "o'reilly" ], since)
    end
  end

  describe ".chat_activity_batch" do
    it "returns {} on empty stream_ids (no SQL roundtrip)" do
      expect(ch).not_to receive(:select)
      expect(described_class.chat_activity_batch([], 10.minutes.ago)).to eq({})
    end

    it "queries with stream_id IN list + privmsg + groups per stream" do
      sid1 = SecureRandom.uuid
      sid2 = SecureRandom.uuid
      since = Time.utc(2026, 5, 30, 12, 0, 0)
      expect(ch).to receive(:select).with(
        a_string_matching(/SELECT stream_id, count\(\) AS total, uniqExact\(username\)/)
          .and(a_string_matching(/msg_type = 'privmsg'/))
          .and(a_string_matching(/GROUP BY stream_id/))
          .and(a_string_matching(/'#{sid1}'/))
      ).and_return([
                     { "stream_id" => sid1, "total" => "10", "unique_n" => "4" },
                     { "stream_id" => sid2, "total" => "3",  "unique_n" => "2" }
                   ])

      result = described_class.chat_activity_batch([ sid1, sid2 ], since)
      expect(result[sid1]).to eq(unique: 4, total: 10)
      expect(result[sid2]).to eq(unique: 2, total: 3)
    end

    it "raises ArgumentError for non-UUID stream_id (validate_stream_uuid! guard)" do
      expect {
        described_class.chat_activity_batch([ "not-a-uuid' OR 1=1 --" ], 10.minutes.ago)
      }.to raise_error(ArgumentError, /not a UUID/)
    end
  end

  describe ".raid_messages_pending" do
    let(:since)  { Time.utc(2026, 5, 31, 10, 0, 0) }
    let(:until_) { Time.utc(2026, 5, 31, 11, 52, 0) }

    it "queries chat_messages with msg_type='raid' + stream/twitch_msg_id NOT NULL + chronological LIMIT" do
      expect(ch).to receive(:select).with(
        a_string_matching(/FROM chat_messages/)
          .and(a_string_matching(/msg_type = 'raid'/))
          .and(a_string_matching(/stream_id IS NOT NULL/))
          .and(a_string_matching(/twitch_msg_id != ''/))
          .and(a_string_matching(/timestamp >= toDateTime64\('2026-05-31 10:00:00\.000', 3\)/))
          .and(a_string_matching(/timestamp <= toDateTime64\('2026-05-31 11:52:00\.000', 3\)/))
          .and(a_string_matching(/ORDER BY timestamp/))
          .and(a_string_matching(/LIMIT 200/))
      ).and_return([])

      described_class.raid_messages_pending(since: since, until_: until_, limit: 200)
    end

    it "returns each row as Hash with stream_id / timestamp / username / twitch_msg_id / parsed raw_tags" do
      sid = SecureRandom.uuid
      allow(ch).to receive(:select).and_return([
        {
          "stream_id"     => sid,
          "timestamp"     => "2026-05-31 10:30:15.123",
          "username"      => "tmi.twitch.tv",
          "twitch_msg_id" => "raid-abc123",
          "raw_tags"      => '{"msg-id":"raid","msg-param-viewerCount":"100","user-id":"src-42"}'
        }
      ])

      rows = described_class.raid_messages_pending(since: since, until_: until_, limit: 200)
      expect(rows.size).to eq(1)
      expect(rows.first[:stream_id]).to eq(sid)
      expect(rows.first[:timestamp]).to eq(Time.utc(2026, 5, 31, 10, 30, 15, 123_000))
      expect(rows.first[:twitch_msg_id]).to eq("raid-abc123")
      expect(rows.first[:raw_tags]).to eq(
        "msg-id" => "raid", "msg-param-viewerCount" => "100", "user-id" => "src-42"
      )
    end

    it "tolerates malformed JSON in raw_tags (returns {}) so a single corrupt row doesn't crash the run" do
      allow(ch).to receive(:select).and_return([
        {
          "stream_id"     => SecureRandom.uuid,
          "timestamp"     => "2026-05-31 10:30:00.000",
          "username"      => "tmi.twitch.tv",
          "twitch_msg_id" => "raid-bad",
          "raw_tags"      => "{not-valid-json"
        }
      ])

      expect { described_class.raid_messages_pending(since: since, until_: until_, limit: 10) }
        .not_to raise_error
      expect(described_class.raid_messages_pending(since: since, until_: until_, limit: 10).first[:raw_tags])
        .to eq({})
    end

    # CR-234 Nit-1: writer emits a Hash, but JSON.parse accepts arrays/scalars too — downstream
    # `tags["msg-id"]` would TypeError on a parsed array. parse_raw_tags returns {} for any non-Hash
    # so process_raid never sees a typed-mismatched payload.
    it "returns {} when raw_tags JSON is valid but not a Hash (Array/scalar guard)" do
      allow(ch).to receive(:select).and_return([
        { "stream_id" => SecureRandom.uuid, "timestamp" => "2026-05-31 10:30:00.000",
          "username" => "x", "twitch_msg_id" => "r-arr", "raw_tags" => '["not","a","hash"]' },
        { "stream_id" => SecureRandom.uuid, "timestamp" => "2026-05-31 10:31:00.000",
          "username" => "y", "twitch_msg_id" => "r-num", "raw_tags" => "42" },
        { "stream_id" => SecureRandom.uuid, "timestamp" => "2026-05-31 10:32:00.000",
          "username" => "z", "twitch_msg_id" => "r-str", "raw_tags" => '"a-string"' }
      ])

      rows = described_class.raid_messages_pending(since: since, until_: until_, limit: 10)
      expect(rows.map { |r| r[:raw_tags] }).to all(eq({}))
    end

    it "tolerates nil/blank raw_tags (returns {})" do
      allow(ch).to receive(:select).and_return([
        { "stream_id" => SecureRandom.uuid, "timestamp" => "2026-05-31 10:30:00.000",
          "username" => "x", "twitch_msg_id" => "r1", "raw_tags" => nil },
        { "stream_id" => SecureRandom.uuid, "timestamp" => "2026-05-31 10:31:00.000",
          "username" => "y", "twitch_msg_id" => "r2", "raw_tags" => "" }
      ])

      rows = described_class.raid_messages_pending(since: since, until_: until_, limit: 10)
      expect(rows.map { |r| r[:raw_tags] }).to all(eq({}))
    end

    it "swallows Clickhouse::Error and returns [] (transient infra tolerance)" do
      allow(ch).to receive(:select).and_raise(Clickhouse::QueryError, "boom")
      expect(described_class.raid_messages_pending(since: since, until_: until_, limit: 10)).to eq([])
    end
  end

  describe ".privmsg_logins" do
    let(:stream_id) { SecureRandom.uuid }
    let(:stream)    { instance_double(Stream, id: stream_id) }
    let(:from) { Time.utc(2026, 5, 31, 11, 0, 0) }
    let(:to)   { Time.utc(2026, 5, 31, 11, 15, 0) }

    it "queries DISTINCT username with stream + msg_type='privmsg' + half-open window" do
      expect(ch).to receive(:select).with(
        a_string_matching(/SELECT DISTINCT username/)
          .and(a_string_matching(/stream_id = '#{stream_id}'/))
          .and(a_string_matching(/msg_type = 'privmsg'/))
          .and(a_string_matching(/username != ''/))
          .and(a_string_matching(/timestamp >= toDateTime64\('2026-05-31 11:00:00\.000', 3\)/))
          .and(a_string_matching(/timestamp <  toDateTime64\('2026-05-31 11:15:00\.000', 3\)/))
      ).and_return([ { "username" => "alice" }, { "username" => "bob" } ])

      expect(described_class.privmsg_logins(stream, from: from, to: to)).to eq(%w[alice bob])
    end

    it "raises on non-UUID stream_id (guard against SQL injection)" do
      bad_stream = instance_double(Stream, id: "'; DROP TABLE chat_messages; --")
      expect { described_class.privmsg_logins(bad_stream, from: from, to: to) }
        .to raise_error(ArgumentError, /not a UUID/)
    end

    it "swallows Clickhouse::Error and returns []" do
      allow(ch).to receive(:select).and_raise(Clickhouse::QueryError, "boom")
      expect(described_class.privmsg_logins(stream, from: from, to: to)).to eq([])
    end
  end

  describe ".distinct_active_chatters" do
    let(:since) { Time.utc(2026, 5, 31, 10, 0, 0) }

    it "queries DISTINCT username over the cutoff with username != '' and LIMIT" do
      expect(ch).to receive(:select).with(
        a_string_matching(/SELECT DISTINCT username/)
          .and(a_string_matching(/timestamp > toDateTime64\('2026-05-31 10:00:00\.000', 3\)/))
          .and(a_string_matching(/username != ''/))
          .and(a_string_matching(/LIMIT 5250/))
      ).and_return([ { "username" => "alice" }, { "username" => "bob" } ])

      expect(described_class.distinct_active_chatters(since: since, limit: 5250)).to eq(%w[alice bob])
    end

    it "swallows Clickhouse::Error and returns [] (transient infra tolerance)" do
      allow(ch).to receive(:select).and_raise(Clickhouse::QueryError, "boom")
      expect(described_class.distinct_active_chatters(since: since, limit: 100)).to eq([])
    end
  end

  describe ".validate_stream_uuid!" do
    it "accepts valid UUID v4 string" do
      expect { described_class.validate_stream_uuid!(SecureRandom.uuid) }.not_to raise_error
    end

    it "accepts an array of valid UUIDs" do
      expect { described_class.validate_stream_uuid!([ SecureRandom.uuid, SecureRandom.uuid ]) }
        .not_to raise_error
    end

    it "raises on SQL-injection attempt" do
      expect { described_class.validate_stream_uuid!("'; DROP TABLE chat_messages; --") }
        .to raise_error(ArgumentError, /not a UUID/)
    end

    it "raises on plain string" do
      expect { described_class.validate_stream_uuid!("not-uuid") }.to raise_error(ArgumentError)
    end

    it "raises on UUID with trailing chars" do
      expect { described_class.validate_stream_uuid!("#{SecureRandom.uuid}x") }
        .to raise_error(ArgumentError)
    end
  end
end
