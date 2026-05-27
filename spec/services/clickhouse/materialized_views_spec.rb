# frozen_string_literal: true

require "rails_helper"

# Aggregation-correctness for the PR 1a-2 materialized views, against a real ClickHouse (the CI
# `clickhouse` service; skipped locally without one). Inserts a controlled sample into chat_messages
# — including a non-privmsg row and a NULL-stream_id row that the MVs MUST exclude (mirroring
# ContextBuilder's `msg_type='privmsg' AND stream_id present` filter) — then asserts the *Merge reads
# equal the hand-computed expected. Each example uses a unique stream_id so the shared CI CH instance
# (other specs also write chat_messages) stays isolated without cleanup.
RSpec.describe "Clickhouse materialized views", :clickhouse do
  let(:client) { Clickhouse.client }
  let(:stream_id) { SecureRandom.uuid }
  let(:m0) { "2026-05-27 12:00:00.000" } # minute bucket 0
  let(:m1) { "2026-05-27 12:01:00.000" } # minute bucket 1

  # privmsg sample → minute0: alice×2, bob×1 ; minute1: alice×1, carol×1
  # excluded: a 'sub' row (alice, minute0) and a privmsg with NULL stream_id (dave).
  let(:rows) do
    [
      { stream_id: stream_id, channel_login: "ch", username: "alice", msg_type: "privmsg", timestamp: m0 },
      { stream_id: stream_id, channel_login: "ch", username: "alice", msg_type: "privmsg", timestamp: m0 },
      { stream_id: stream_id, channel_login: "ch", username: "bob",   msg_type: "privmsg", timestamp: m0 },
      { stream_id: stream_id, channel_login: "ch", username: "alice", msg_type: "privmsg", timestamp: m1 },
      { stream_id: stream_id, channel_login: "ch", username: "carol", msg_type: "privmsg", timestamp: m1 },
      # excluded — wrong msg_type (must NOT inflate alice's count):
      { stream_id: stream_id, channel_login: "ch", username: "alice", msg_type: "sub", timestamp: m0 },
      # excluded — NULL stream_id (stream_id omitted → NULL):
      { channel_login: "ch", username: "dave", msg_type: "privmsg", timestamp: m0 }
    ]
  end

  before do
    skip "ClickHouse not reachable (set CLICKHOUSE_HOST + run clickhouse:setup)" unless client.ping
    client.insert("chat_messages", rows)
  end

  describe "mv_stream_minute (fetch_chat_rate + fetch_unique_chatters)" do
    it "countMerge per minute = privmsg/min, excluding non-privmsg and NULL-stream rows" do
      per_minute = client.select(
        "SELECT countMerge(msg_count) AS c FROM mv_stream_minute_target " \
        "WHERE stream_id = '#{stream_id}' GROUP BY minute ORDER BY minute"
      )
      expect(per_minute.map { |r| r["c"].to_i }).to eq([ 3, 2 ]) # minute0=3 (alice×2+bob), minute1=2 (alice+carol)
    end

    it "uniqExactMerge over the whole window = distinct chatters (60min-equivalent read)" do
      agg = client.select(
        "SELECT countMerge(msg_count) AS c, uniqExactMerge(unique_chatters) AS u " \
        "FROM mv_stream_minute_target WHERE stream_id = '#{stream_id}'"
      ).first
      expect(agg["c"].to_i).to eq(5)  # 5 privmsg total (sub + null-stream excluded)
      expect(agg["u"].to_i).to eq(3)  # alice, bob, carol
    end

    it "uniqExactMerge per minute = distinct chatters that minute" do
      per_minute = client.select(
        "SELECT uniqExactMerge(unique_chatters) AS u FROM mv_stream_minute_target " \
        "WHERE stream_id = '#{stream_id}' GROUP BY minute ORDER BY minute"
      )
      expect(per_minute.map { |r| r["u"].to_i }).to eq([ 2, 2 ]) # m0={alice,bob}, m1={alice,carol}
    end
  end

  describe "mv_stream_user_minute (fetch_chat_username_counts → entropy)" do
    it "countMerge per username over the window = per-user privmsg counts" do
      per_user = client.select(
        "SELECT username, countMerge(msg_count) AS c FROM mv_stream_user_minute_target " \
        "WHERE stream_id = '#{stream_id}' GROUP BY username ORDER BY username"
      )
      expect(per_user.map { |r| [ r["username"], r["c"].to_i ] }).to eq([ [ "alice", 3 ], [ "bob", 1 ], [ "carol", 1 ] ])
    end
  end
end
