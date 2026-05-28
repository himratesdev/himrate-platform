# frozen_string_literal: true

require "rails_helper"

# TASK-251.14b: end-to-end dual-write against a REAL ClickHouse (the CI `clickhouse` service; skipped
# locally). Proves the worker's CH mirror lands rows in chat_messages AND the PR-1a-2 MVs populate
# from them — tying 1a (raw table) + 1a-2 (MVs) + 1b (dual-write) together. Postgres + Redis are real.
# Each example uses a unique channel/stream so the shared CI CH instance stays isolated without cleanup.
RSpec.describe "ChatMessageWorker ClickHouse dual-write (integration)", :clickhouse do
  let(:worker) { ChatMessageWorker.new }
  let(:redis_url) { "redis://localhost:6379/1" }
  let(:redis_key) { "irc:chat_messages" }
  let(:ch) { Clickhouse.client }
  let(:login) { "ch_dw_#{SecureRandom.hex(4)}" }
  let!(:channel) { create(:channel, login: login) }
  let!(:stream) { create(:stream, channel: channel, ended_at: nil) }

  before do
    skip "ClickHouse not reachable (run clickhouse:setup against a CH server)" unless ch.ping
    Redis.new(url: redis_url).del(redis_key)
    allow(ENV).to receive(:fetch).and_call_original
    allow(ENV).to receive(:fetch).with("REDIS_URL", anything).and_return(redis_url)
    allow(Flipper).to receive(:enabled?).and_call_original
    allow(Flipper).to receive(:enabled?).with(:chat_writes_clickhouse).and_return(true)
  rescue Redis::CannotConnectError
    skip "Redis not available"
  end

  def push(data)
    Redis.new(url: redis_url).lpush(redis_key, JSON.generate(data))
  end

  def msg(overrides = {})
    { channel_login: login, username: "alice", message_text: "hi", msg_type: "privmsg",
      raw_tags: { "x" => "y" }, timestamp: Time.current.iso8601 }.merge(overrides)
  end

  it "mirrors privmsg rows into ClickHouse chat_messages with Postgres parity" do
    push(msg)
    push(msg(username: "bob"))
    push(msg(message_text: "again"))

    expect { worker.perform }.to change(ChatMessage, :count).by(3)

    pg_count = ChatMessage.where(stream_id: stream.id).count
    ch_count = ch.select("SELECT count() AS c FROM chat_messages WHERE stream_id = '#{stream.id}'").first["c"].to_i
    expect(ch_count).to eq(pg_count).and(eq(3))
  end

  it "populates the mv_stream_minute rollup from the mirrored rows" do
    push(msg)
    push(msg(username: "bob"))
    worker.perform

    agg = ch.select(
      "SELECT countMerge(msg_count) AS c, uniqExactMerge(unique_chatters) AS u " \
      "FROM mv_stream_minute_target WHERE stream_id = '#{stream.id}'"
    ).first
    expect(agg["c"].to_i).to eq(2) # 2 privmsg
    expect(agg["u"].to_i).to eq(2) # alice, bob
  end
end
