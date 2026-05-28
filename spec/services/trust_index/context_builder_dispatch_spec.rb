# frozen_string_literal: true

require "rails_helper"

# TASK-251.14d: dispatch-layer tests for the 4 chat queries — verifies the flag semantics that
# couple ContextBuilder to either PG (default), dual-read (validation, returns PG + logs
# divergence), or CH-only (combat). The PG/CH implementation paths themselves are exercised by the
# existing context_builder_spec.rb (PG) and chat_queries_spec.rb (CH).
RSpec.describe TrustIndex::ContextBuilder, "dispatch (TASK-251.14d)" do
  let(:channel) { Channel.create!(twitch_id: "cb_d", login: "cb_d", display_name: "CBD") }
  let(:stream) { Stream.create!(channel: channel, started_at: 1.hour.ago, game_name: "Just Chatting") }

  # Indirect via dispatch_chat: we stub the leaf _pg/_ch methods on the singleton class.
  before do
    allow(Flipper).to receive(:enabled?).and_call_original
    allow(described_class).to receive(:fetch_chat_rate_pg).and_return([ { msg_count: 9, timestamp: Time.utc(2026, 5, 28, 12) } ])
    allow(described_class).to receive(:fetch_chat_rate_ch).and_return([ { msg_count: 9, timestamp: Time.utc(2026, 5, 28, 12) } ])
    # Spy pattern for logger — assertions use `have_received` so unrelated warns from other code
    # don't trip the expectations.
    allow(Rails.logger).to receive(:warn).and_call_original
  end

  context "default (both flags OFF) → PG only" do
    before do
      allow(Flipper).to receive(:enabled?).with(:chat_reads_clickhouse_dual_read).and_return(false)
      allow(Flipper).to receive(:enabled?).with(:chat_reads_clickhouse).and_return(false)
    end

    it "calls the PG path and never touches CH" do
      expect(described_class).to receive(:fetch_chat_rate_pg).and_return([])
      expect(described_class).not_to receive(:fetch_chat_rate_ch)
      described_class.send(:fetch_chat_rate, stream, 10.minutes.ago)
    end
  end

  context ":chat_reads_clickhouse ON (without dual_read) → CH only" do
    before do
      allow(Flipper).to receive(:enabled?).with(:chat_reads_clickhouse_dual_read).and_return(false)
      allow(Flipper).to receive(:enabled?).with(:chat_reads_clickhouse).and_return(true)
    end

    it "calls the CH path and never touches PG" do
      expect(described_class).to receive(:fetch_chat_rate_ch).and_return([])
      expect(described_class).not_to receive(:fetch_chat_rate_pg)
      described_class.send(:fetch_chat_rate, stream, 10.minutes.ago)
    end
  end

  context ":chat_reads_clickhouse_dual_read ON → query both, return PG, log on divergence" do
    before do
      allow(Flipper).to receive(:enabled?).with(:chat_reads_clickhouse_dual_read).and_return(true)
      allow(Flipper).to receive(:enabled?).with(:chat_reads_clickhouse).and_return(false)
    end

    it "calls both paths and returns the PG result (safe default during validation)" do
      pg_result = [ { msg_count: 9, timestamp: Time.utc(2026, 5, 28, 12) } ]
      allow(described_class).to receive(:fetch_chat_rate_pg).and_return(pg_result)
      allow(described_class).to receive(:fetch_chat_rate_ch).and_return(pg_result)
      expect(described_class).to receive(:fetch_chat_rate_pg)
      expect(described_class).to receive(:fetch_chat_rate_ch)
      expect(described_class.send(:fetch_chat_rate, stream, 10.minutes.ago)).to eq(pg_result)
    end

    it "logs divergence when PG and CH disagree (silent on exact match)" do
      pg_result = [ { msg_count: 9, timestamp: Time.utc(2026, 5, 28, 12) } ]
      ch_result = [ { msg_count: 8, timestamp: Time.utc(2026, 5, 28, 12) } ]
      allow(described_class).to receive(:fetch_chat_rate_pg).and_return(pg_result)
      allow(described_class).to receive(:fetch_chat_rate_ch).and_return(ch_result)

      described_class.send(:fetch_chat_rate, stream, 10.minutes.ago)
      expect(Rails.logger).to have_received(:warn).with(a_string_matching(/dual-read divergence: method=chat_rate stream_id=#{stream.id}/))
    end

    it "is silent on exact-match (0-divergence: the post-cutover target state)" do
      same = [ { msg_count: 9, timestamp: Time.utc(2026, 5, 28, 12) } ]
      allow(described_class).to receive(:fetch_chat_rate_pg).and_return(same)
      allow(described_class).to receive(:fetch_chat_rate_ch).and_return(same)

      described_class.send(:fetch_chat_rate, stream, 10.minutes.ago)
      expect(Rails.logger).not_to have_received(:warn).with(a_string_matching(/divergence/))
    end

    it "swallows CH errors (CH down ≠ data corruption; logs once, returns PG)" do
      allow(described_class).to receive(:fetch_chat_rate_ch).and_raise(Clickhouse::ConnectionError, "down")
      pg_result = [ { msg_count: 5, timestamp: Time.utc(2026, 5, 28, 12) } ]
      allow(described_class).to receive(:fetch_chat_rate_pg).and_return(pg_result)

      expect(described_class.send(:fetch_chat_rate, stream, 10.minutes.ago)).to eq(pg_result)
      expect(Rails.logger).to have_received(:warn).with(a_string_matching(/CH chat_rate failed/))
      expect(Rails.logger).not_to have_received(:warn).with(a_string_matching(/divergence/))
    end
  end

  describe "minute-alignment of `since` (CR-198 Nit-2)" do
    before do
      allow(Flipper).to receive(:enabled?).with(:chat_reads_clickhouse_dual_read).and_return(false)
      allow(Flipper).to receive(:enabled?).with(:chat_reads_clickhouse).and_return(false)
    end

    it "floors the `since` argument to the minute before dispatch (PG and CH read identical windows)" do
      sub_minute = Time.utc(2026, 5, 28, 12, 5, 37)
      expect(described_class).to receive(:fetch_chat_rate_pg).with(stream, Time.utc(2026, 5, 28, 12, 5, 0))
      described_class.send(:fetch_chat_rate, stream, sub_minute)
    end
  end
end
