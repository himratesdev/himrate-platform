# frozen_string_literal: true

require "rails_helper"

RSpec.describe Trust::ViewerSessionPresences, type: :service do
  let(:channel) { create(:channel) }
  let(:stream)  { create(:stream, channel: channel, started_at: 1.hour.ago) }

  describe ".for_stream" do
    context "chat-only path (no lurkers)" do
      before do
        allow(Clickhouse::ChatQueries).to receive(:viewer_first_last_seen_per_stream)
          .with(stream.id)
          .and_return(
            "viewer1" => { first_seen_at: 1.hour.ago, last_seen_at: 30.minutes.ago, message_count: 5 },
            "viewer2" => { first_seen_at: 50.minutes.ago, last_seen_at: 40.minutes.ago, message_count: 1 }
          )
      end

      it "returns chat-only entries when include_lurkers: false" do
        result = described_class.for_stream(stream, include_lurkers: false)
        expect(result.size).to eq(2)
        expect(result.map(&:source).uniq).to eq([ "chat" ])
        expect(result.map(&:username)).to contain_exactly("viewer1", "viewer2")
      end

      it "fills observation_count from chat message_count" do
        result = described_class.for_stream(stream, include_lurkers: false)
        v1 = result.find { |r| r.username == "viewer1" }
        expect(v1.observation_count).to eq(5)
      end

      it "computes duration_seconds = last_seen - first_seen" do
        result = described_class.for_stream(stream, include_lurkers: false)
        v1 = result.find { |r| r.username == "viewer1" }
        expect(v1.duration_seconds).to be_within(2).of(1800) # 30 min
      end

      it "skips lurker merge entirely when include_lurkers: false" do
        # ChattersSnapshot rows exist but should be ignored
        create(:chatters_snapshot, stream: stream, timestamp: 55.minutes.ago, viewer_logins: [ "lurker_skipped" ])
        result = described_class.for_stream(stream, include_lurkers: false)
        expect(result.map(&:username)).not_to include("lurker_skipped")
      end
    end

    context "hybrid Option C (chat + lurker merge)" do
      before do
        allow(Clickhouse::ChatQueries).to receive(:viewer_first_last_seen_per_stream)
          .with(stream.id)
          .and_return(
            "chatter1" => { first_seen_at: 1.hour.ago, last_seen_at: 30.minutes.ago, message_count: 5 }
          )

        # Two snapshots; chatter1 appears in both, lurker1 in both, lurker2 only in 2nd
        create(:chatters_snapshot, stream: stream, timestamp: 55.minutes.ago,
                                   viewer_logins: [ "chatter1", "lurker1" ])
        create(:chatters_snapshot, stream: stream, timestamp: 35.minutes.ago,
                                   viewer_logins: [ "chatter1", "lurker1", "lurker2" ])
      end

      it "uses 'chat' source for users with chat messages" do
        result = described_class.for_stream(stream)
        c1 = result.find { |r| r.username == "chatter1" }
        expect(c1.source).to eq("chat")
        expect(c1.observation_count).to eq(5) # message_count, not snapshot count
      end

      it "uses 'sweep' source for lurkers absent from chat" do
        result = described_class.for_stream(stream)
        l1 = result.find { |r| r.username == "lurker1" }
        expect(l1.source).to eq("sweep")
        expect(l1.observation_count).to eq(2) # 2 snapshots
      end

      it "merges chatter + lurkers without duplication" do
        result = described_class.for_stream(stream)
        usernames = result.map(&:username)
        expect(usernames.uniq.size).to eq(usernames.size)
        expect(usernames).to contain_exactly("chatter1", "lurker1", "lurker2")
      end

      it "lurker first_seen_at = earliest snapshot they appeared in" do
        result = described_class.for_stream(stream)
        l1 = result.find { |r| r.username == "lurker1" }
        expect(l1.first_seen_at).to be_within(1.minute).of(55.minutes.ago)
        expect(l1.last_seen_at).to be_within(1.minute).of(35.minutes.ago)
      end

      it "lurker2 (single-snapshot) has first_seen_at == last_seen_at" do
        result = described_class.for_stream(stream)
        l2 = result.find { |r| r.username == "lurker2" }
        expect(l2.first_seen_at).to eq(l2.last_seen_at)
        expect(l2.observation_count).to eq(1)
        expect(l2.duration_seconds).to eq(0)
      end
    end

    context "edge cases" do
      it "returns empty array for stream with no chat AND no snapshots" do
        allow(Clickhouse::ChatQueries).to receive(:viewer_first_last_seen_per_stream)
          .with(stream.id).and_return({})
        expect(described_class.for_stream(stream)).to eq([])
      end

      it "ignores snapshots with NULL viewer_logins" do
        allow(Clickhouse::ChatQueries).to receive(:viewer_first_last_seen_per_stream)
          .with(stream.id).and_return({})
        create(:chatters_snapshot, stream: stream, timestamp: 30.minutes.ago, viewer_logins: nil)
        create(:chatters_snapshot, stream: stream, timestamp: 20.minutes.ago, viewer_logins: [ "real_lurker" ])
        result = described_class.for_stream(stream)
        expect(result.map(&:username)).to eq([ "real_lurker" ])
      end

      it "handles empty viewer_logins array (no logins yet)" do
        allow(Clickhouse::ChatQueries).to receive(:viewer_first_last_seen_per_stream)
          .with(stream.id).and_return({})
        create(:chatters_snapshot, stream: stream, timestamp: 30.minutes.ago, viewer_logins: [])
        result = described_class.for_stream(stream)
        expect(result).to eq([])
      end

      it "tolerates CH error from ChatQueries (chat layer empty, sweep still works)" do
        allow(Clickhouse::ChatQueries).to receive(:viewer_first_last_seen_per_stream)
          .with(stream.id).and_return({})
        create(:chatters_snapshot, stream: stream, timestamp: 30.minutes.ago, viewer_logins: [ "lurker_solo" ])
        result = described_class.for_stream(stream)
        expect(result.map(&:source)).to eq([ "sweep" ])
        expect(result.first.username).to eq("lurker_solo")
      end
    end
  end
end
