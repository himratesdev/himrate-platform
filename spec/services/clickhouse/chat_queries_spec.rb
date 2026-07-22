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

  # TI v2.1 BUG-A: the trailing-window roster (cumulative stream_chatters + timestamp filter).
  describe ".stream_chatters_windowed" do
    it "adds the trailing-window timestamp filter to the deterministic roster query" do
      since = Time.utc(2026, 7, 22, 5, 0, 0)
      expect(ch).to receive(:select).with(
        a_string_matching(/SELECT DISTINCT username/)
          .and(a_string_matching(/stream_id = '#{stream.id}'/))
          .and(a_string_matching(/timestamp > toDateTime\('2026-07-22 05:00:00'\)/))
          .and(a_string_matching(/ORDER BY username/))
          .and(a_string_matching(/LIMIT 500/))
      ).and_return([ { "username" => "alice" } ])

      expect(described_class.stream_chatters_windowed(stream, since: since)).to eq(%w[alice])
    end

    it "returns [] (and logs) on a CH error" do
      expect(ch).to receive(:select).and_raise(Clickhouse::QueryError.new("CH down"))
      expect(Rails.logger).to receive(:warn).with(/stream_chatters_windowed failed/)

      expect(described_class.stream_chatters_windowed(stream, since: Time.utc(2026, 7, 22, 5, 0, 0))).to eq([])
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

    # BUG-OVERLAP-DOUBLESCAN — re-runnable real-CH guard for the single-pass cohort semantics.
    # The mocked specs only assert query SHAPE; this proves the `count() OVER (PARTITION BY username)`
    # cohort filter actually behaves like the old `HAVING uniqExact(channel_login) BETWEEN 2 AND cap`:
    # single-channel users excluded, 2..cap users returned one-row-per-channel with correct counts,
    # over-cap users excluded, cap boundary inclusive. Usernames are randomised so the all-channel
    # 24h scan does not collide with rows other examples insert into the shared table.
    it "cross_channel_edges returns exactly the 2..cap overlap cohort, one row per (username, channel)" do
      sfx    = SecureRandom.hex(4)
      single = "edge_single_#{sfx}" # 1 channel  → excluded
      pair   = "edge_pair_#{sfx}"   # 2 channels → included
      capped = "edge_cap_#{sfx}"    # 3 channels (== cap) → included (inclusive boundary)
      omni   = "edge_omni_#{sfx}"   # 4 channels (> cap)  → excluded
      base   = t - 30.minutes

      insert([
               { username: single, channel_login: "c1_#{sfx}", timestamp: base + 1.second },
               { username: pair,   channel_login: "c1_#{sfx}", timestamp: base + 2.seconds },
               { username: pair,   channel_login: "c1_#{sfx}", timestamp: base + 3.seconds }, # 2 msgs in c1
               { username: pair,   channel_login: "c2_#{sfx}", timestamp: base + 4.seconds }, # 1 msg in c2
               { username: capped, channel_login: "c1_#{sfx}", timestamp: base + 5.seconds },
               { username: capped, channel_login: "c2_#{sfx}", timestamp: base + 6.seconds },
               { username: capped, channel_login: "c3_#{sfx}", timestamp: base + 7.seconds },
               { username: omni,   channel_login: "c1_#{sfx}", timestamp: base + 8.seconds },
               { username: omni,   channel_login: "c2_#{sfx}", timestamp: base + 9.seconds },
               { username: omni,   channel_login: "c3_#{sfx}", timestamp: base + 10.seconds },
               { username: omni,   channel_login: "c4_#{sfx}", timestamp: base + 11.seconds }
             ])

      rows    = described_class.cross_channel_edges(3, 1_000_000)
      by_user = rows.select { |r| [ single, pair, capped, omni ].include?(r["username"]) }.group_by { |r| r["username"] }

      expect(by_user).not_to have_key(single) # single-channel → no overlap edge
      expect(by_user).not_to have_key(omni)   # over-cap → omnipresent, kept out of the graph

      pair_rows = (by_user[pair] || []).to_h { |r| [ r["channel_login"], r["message_count"].to_i ] }
      expect(pair_rows).to eq("c1_#{sfx}" => 2, "c2_#{sfx}" => 1) # one row per channel, correct counts

      expect((by_user[capped] || []).map { |r| r["channel_login"] })
        .to contain_exactly("c1_#{sfx}", "c2_#{sfx}", "c3_#{sfx}") # cap boundary inclusive
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

  # PR #259 (2026-06-02 perf-debt): single CH scan returning all 3 per-user arrays
  # (timestamps + messages + emote_strings) — replaces 3 separate full-scans on chat_messages.
  describe ".chatter_raw_data" do
    let(:stream) { instance_double(Stream, id: stream_id) }

    it "issues ONE CH scan returning all per-user arrays grouped by username" do
      expect(ch).to receive(:select).with(
        a_string_matching(/SELECT username, timestamp, message_text, emotes/)
          .and(a_string_matching(/stream_id = '#{stream_id}'/))
          .and(a_string_matching(/msg_type = 'privmsg'/))
          .and(a_string_matching(/username != ''/))
          .and(a_string_matching(/ORDER BY username, timestamp/))
      ).and_return([
                     { "username" => "alice", "timestamp" => "2026-06-02 12:00:00", "message_text" => "hi",    "emotes" => "" },
                     { "username" => "alice", "timestamp" => "2026-06-02 12:00:01", "message_text" => "bye",   "emotes" => "25:0-4" },
                     { "username" => "alice", "timestamp" => "2026-06-02 12:00:05", "message_text" => "",      "emotes" => "" },
                     { "username" => "bob",   "timestamp" => "2026-06-02 12:01:00", "message_text" => "hello", "emotes" => "50:0-3" }
                   ])

      result = described_class.chatter_raw_data(stream)

      expect(result.keys).to match_array(%w[alice bob])
      expect(result["alice"][:timestamps].size).to eq(3) # all rows
      expect(result["alice"][:timestamps].first).to be_a(Time)
      expect(result["alice"][:messages]).to eq(%w[hi bye]) # message_text != '' filter
      expect(result["alice"][:emote_strings]).to eq([ "25:0-4" ])  # emotes != '' filter
      expect(result["bob"][:timestamps].size).to eq(1)
      expect(result["bob"][:messages]).to eq([ "hello" ])
      expect(result["bob"][:emote_strings]).to eq([ "50:0-3" ])
    end

    it "returns {} on Clickhouse::Error (graceful — BSW skips enrichment, falls back to base scoring)" do
      allow(ch).to receive(:select).and_raise(Clickhouse::QueryError, "boom")
      expect(described_class.chatter_raw_data(stream)).to eq({})
    end

    it "validates stream UUID (rejects malformed input)" do
      bad_stream = instance_double(Stream, id: "not-a-uuid")
      expect { described_class.chatter_raw_data(bad_stream) }.to raise_error(ArgumentError, /not a UUID/)
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

  describe ".chatters_on_streams (BUG-C fraud-priority set)" do
    let(:sid1) { "11111111-1111-4111-8111-111111111111" }
    let(:sid2) { "22222222-2222-4222-8222-222222222222" }

    it "queries DISTINCT username over the given stream_ids with the privmsg + non-empty filter" do
      expect(ch).to receive(:select).with(
        a_string_matching(/SELECT DISTINCT username/)
          .and(a_string_matching(/stream_id IN \('#{sid1}','#{sid2}'\)/))
          .and(a_string_matching(/msg_type = 'privmsg'/))
          .and(a_string_matching(/username != ''/))
          .and(a_string_matching(/LIMIT 9000/))
      ).and_return([ { "username" => "livefake" }, { "username" => "realchatter" } ])

      expect(described_class.chatters_on_streams([ sid1, sid2 ], limit: 9000)).to eq(%w[livefake realchatter])
    end

    it "returns [] for an empty stream set without hitting ClickHouse" do
      expect(ch).not_to receive(:select)
      expect(described_class.chatters_on_streams([], limit: 100)).to eq([])
    end

    it "raises ArgumentError on a non-UUID stream_id (bad caller, sibling convention)" do
      expect { described_class.chatters_on_streams(%w[not-a-uuid], limit: 100) }.to raise_error(ArgumentError, /not a UUID/)
    end

    it "swallows Clickhouse::Error and returns []" do
      allow(ch).to receive(:select).and_raise(Clickhouse::QueryError, "boom")
      expect(described_class.chatters_on_streams([ sid1 ], limit: 100)).to eq([])
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

  # 2026-06-03 BUG-chat-feature-aggregates-mean-inter-msg-sec regression guard.
  # Documents the SQL contract that fixed the lagInFrame first-row outlier
  # (mean=1,116,996s on mogorree pre-fix → 14.578s post-fix, staging 2026-06-03).
  # Locks in the row_number-gating shape so a future refactor (e.g. swap
  # `lagInFrame` for `neighbor()`, or removal of `rn`) silently reintroducing
  # the 1.7e6-sec first-row outlier into stream_feature_vectors MLFE training
  # rows would fail the spec.
  describe ".chat_feature_aggregates" do
    it "renders timing subquery with row_number gating + lagInFrame ORDER BY timestamp" do
      # Query #1 (counts + entropy) and Query #2 (single_message_chatters) are
      # also asserted to lock the 3-query shape and prevent accidental
      # consolidation (Phase 6 L profiling 2026-06-03 showed CH CTE inlining
      # makes consolidation 2-4× SLOWER).
      expect(ch).to receive(:select).with(
        a_string_matching(/WITH stream_msgs AS/)
          .and(a_string_matching(/stream_id = '#{stream_id}' AND msg_type = 'privmsg' AND username != ''/))
          .and(a_string_matching(/uniqExact\(message_text\)/))
      ).and_return([ {
        "total_messages" => 1673,
        "unique_messages" => 1200,
        "unique_chatters" => 166,
        "messages_with_emotes" => 200,
        "message_entropy_bits" => 5.2
      } ])

      expect(ch).to receive(:select).with(
        a_string_matching(/GROUP BY username HAVING count\(\) = 1/)
      ).and_return([ { "single_message_chatters" => 58 } ])

      expect(ch).to receive(:select).with(
        # CR-271 S1 — these two assertions are the regression guard for the
        # 2026-06-03 mean_inter_msg_sec bug:
        a_string_matching(/row_number\(\) OVER \(ORDER BY timestamp\) AS rn/)
          .and(a_string_matching(/WHERE rn > 1 AND diff_sec > 0/))
          .and(a_string_matching(/lagInFrame\(timestamp, 1\) OVER \(ORDER BY timestamp\)/))
      ).and_return([ { "mean_inter_msg_sec" => 14.578, "std_inter_msg_sec" => 24.721 } ])

      result = described_class.chat_feature_aggregates(stream)
      expect(result).to include(
        total_messages: 1673,
        unique_messages: 1200,
        unique_chatters: 166,
        messages_with_emotes: 200,
        message_entropy_bits: 5.2,
        single_message_chatters: 58,
        mean_inter_msg_sec: 14.578,
        std_inter_msg_sec: 24.721
      )
    end
  end

  describe ".viewer_first_last_seen_per_stream" do
    # G-4 BUG-251.31 PR-B: returns { username => { first_seen_at: Time, last_seen_at: Time,
    # observation_count: Integer } } from chat_messages MIN/MAX(timestamp) per username.
    # Bloom_filter idx_stream_id (PR #273) makes this cheap on the stream_id-only filter.

    it "queries chat_messages with stream_id + privmsg + non-empty username, group by username" do
      expect(ch).to receive(:select).with(
        a_string_matching(/SELECT username,/)
          .and(a_string_matching(/toUnixTimestamp64Milli\(min\(timestamp\)\) AS first_seen_ms/))
          .and(a_string_matching(/toUnixTimestamp64Milli\(max\(timestamp\)\) AS last_seen_ms/))
          .and(a_string_matching(/count\(\) AS observation_count/))
          .and(a_string_matching(/FROM chat_messages/))
          .and(a_string_matching(/stream_id = '#{stream_id}'/))
          .and(a_string_matching(/msg_type = 'privmsg'/))
          .and(a_string_matching(/username != ''/))
          .and(a_string_matching(/GROUP BY username/))
      ).and_return([])

      expect(described_class.viewer_first_last_seen_per_stream(stream_id)).to eq({})
    end

    it "converts CH ms timestamps to UTC Time objects" do
      first_ms = Time.utc(2026, 5, 28, 12, 5, 0).to_i * 1000
      last_ms = Time.utc(2026, 5, 28, 12, 30, 0).to_i * 1000
      allow(ch).to receive(:select).and_return([
                                                 {
                                                   "username" => "alice",
                                                   "first_seen_ms" => first_ms.to_s,
                                                   "last_seen_ms" => last_ms.to_s,
                                                   "observation_count" => "5"
                                                 }
                                               ])

      result = described_class.viewer_first_last_seen_per_stream(stream_id)
      expect(result["alice"][:first_seen_at]).to eq(Time.zone.at(first_ms / 1000.0))
      expect(result["alice"][:last_seen_at]).to eq(Time.zone.at(last_ms / 1000.0))
      expect(result["alice"][:observation_count]).to eq(5)
    end

    it "returns one entry per distinct username" do
      allow(ch).to receive(:select).and_return([
                                                 { "username" => "alice", "first_seen_ms" => "1717000000000", "last_seen_ms" => "1717000060000", "observation_count" => "2" },
                                                 { "username" => "bob",   "first_seen_ms" => "1717000010000", "last_seen_ms" => "1717000180000", "observation_count" => "8" }
                                               ])

      result = described_class.viewer_first_last_seen_per_stream(stream_id)
      expect(result.keys).to contain_exactly("alice", "bob")
      expect(result["bob"][:observation_count]).to eq(8)
    end

    it "raises ArgumentError for non-UUID stream_id (validate_stream_uuid! guard)" do
      expect {
        described_class.viewer_first_last_seen_per_stream("not-a-uuid' OR 1=1 --")
      }.to raise_error(ArgumentError, /not a UUID/)
    end

    it "returns empty hash on Clickhouse::Error (fail-open for sweep fallback composition)" do
      allow(ch).to receive(:select).and_raise(Clickhouse::Error.new("connection refused"))
      expect(described_class.viewer_first_last_seen_per_stream(stream_id)).to eq({})
    end
  end

  # T1-057 — these two methods intentionally do NOT rescue Clickhouse::Error (the worker needs to
  # distinguish a CH failure from an empty result for per-section failure isolation), so a raised
  # error must propagate.
  describe ".cross_channel_edges" do
    it "queries the overlap cohort (2..cap distinct channels) grouped by username, channel_login, bounded by row_cap" do
      expect(ch).to receive(:select).with(
        a_string_matching(/GROUP BY username, channel_login/)
          .and(a_string_matching(/BETWEEN 2 AND 30/))
          .and(a_string_matching(/min\(timestamp\) AS first_seen/))
          .and(a_string_matching(/LIMIT 500000/))
      ).and_return([ { "username" => "v1", "channel_login" => "c1", "first_seen" => "x", "last_seen" => "y", "message_count" => "3" } ])

      rows = described_class.cross_channel_edges(30, 500_000)
      expect(rows.first["channel_login"]).to eq("c1")
    end

    # BUG-OVERLAP-DOUBLESCAN: the cohort filter is a single-pass window over the grouped result,
    # NOT a correlated subquery that re-scans the 24h slice a second time.
    it "is single-pass — a window over the grouped rows, no inner re-scan subquery" do
      sql = nil
      allow(ch).to receive(:select) { |q| sql = q; [] }
      described_class.cross_channel_edges(30, 500_000)

      expect(sql).to match(/count\(\) OVER \(PARTITION BY username\) AS distinct_channels/)
      expect(sql).to match(/distinct_channels BETWEEN 2 AND 30/)
      expect(sql).not_to match(/username IN \(/)        # no correlated re-scan
      expect(sql.scan(/FROM chat_messages/).size).to eq(1) # the 24h slice is scanned exactly once
    end

    it "lets Clickhouse::Error propagate (no internal rescue)" do
      allow(ch).to receive(:select).and_raise(Clickhouse::Error.new("ch down"))
      expect { described_class.cross_channel_edges(30, 500_000) }.to raise_error(Clickhouse::Error)
    end
  end

  describe ".temporal_co_occurrence" do
    it "builds a two-phase offset grid (phase 0 + W/2) and filters HAVING event_count >= 2" do
      expect(ch).to receive(:select).with(
        a_string_matching(/ARRAY JOIN \[0, 2\] AS phase/) # W=5 -> half=2
          .and(a_string_matching(/subtractSeconds\(timestamp, phase\)/))
          .and(a_string_matching(/INTERVAL 5 SECOND/))
          .and(a_string_matching(/HAVING event_count >= 2/))
      ).and_return([ { "username" => "bot", "event_count" => "9", "max_concurrent" => "3", "last_event_at" => "z" } ])

      rows = described_class.temporal_co_occurrence(5)
      expect(rows.first["event_count"]).to eq("9")
    end

    it "lets Clickhouse::Error propagate (no internal rescue)" do
      allow(ch).to receive(:select).and_raise(Clickhouse::Error.new("ch down"))
      expect { described_class.temporal_co_occurrence(5) }.to raise_error(Clickhouse::Error)
    end
  end
end
