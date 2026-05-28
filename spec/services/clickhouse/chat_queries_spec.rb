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
end
