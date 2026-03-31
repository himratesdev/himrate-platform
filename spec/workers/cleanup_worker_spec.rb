# frozen_string_literal: true

require "rails_helper"

RSpec.describe CleanupWorker, type: :worker do
  describe "sidekiq options" do
    it "uses monitoring queue" do
      expect(described_class.get_sidekiq_options["queue"].to_s).to eq("monitoring")
    end

    it "retries 3 times" do
      expect(described_class.get_sidekiq_options["retry"]).to eq(3)
    end
  end

  describe "#perform" do
    let(:channel) { create(:channel) }
    let(:stream) { create(:stream, channel: channel) }

    context "old signals" do
      it "deletes signals older than 90 days" do
        old_signal = TiSignal.create!(
          stream: stream, timestamp: 91.days.ago,
          signal_type: "auth_ratio", value: 0.5
        )
        recent_signal = TiSignal.create!(
          stream: stream, timestamp: 1.day.ago,
          signal_type: "auth_ratio", value: 0.8
        )

        described_class.new.perform

        expect(TiSignal.exists?(old_signal.id)).to be false
        expect(TiSignal.exists?(recent_signal.id)).to be true
      end
    end

    # TASK-033 TC-011: ccv_snapshots >90d deleted
    context "old ccv_snapshots" do
      it "deletes ccv_snapshots older than 90 days" do
        old = CcvSnapshot.create!(stream: stream, ccv_count: 1000, timestamp: 91.days.ago)
        recent = CcvSnapshot.create!(stream: stream, ccv_count: 2000, timestamp: 1.day.ago)

        described_class.new.perform

        expect(CcvSnapshot.exists?(old.id)).to be false
        expect(CcvSnapshot.exists?(recent.id)).to be true
      end
    end

    # TASK-033 TC-013: chatters_snapshots >90d deleted
    context "old chatters_snapshots" do
      it "deletes chatters_snapshots older than 90 days" do
        old = ChattersSnapshot.create!(stream: stream, unique_chatters_count: 100, total_messages_count: 500, timestamp: 91.days.ago)
        recent = ChattersSnapshot.create!(stream: stream, unique_chatters_count: 200, total_messages_count: 1000, timestamp: 1.day.ago)

        described_class.new.perform

        expect(ChattersSnapshot.exists?(old.id)).to be false
        expect(ChattersSnapshot.exists?(recent.id)).to be true
      end
    end

    # TASK-033 TC-011: chat_messages >90d deleted
    context "old chat_messages" do
      it "deletes chat_messages older than 90 days" do
        old = ChatMessage.create!(stream: stream, channel_login: "test", username: "user1", timestamp: 91.days.ago)
        recent = ChatMessage.create!(stream: stream, channel_login: "test", username: "user2", timestamp: 1.day.ago)

        described_class.new.perform

        expect(ChatMessage.exists?(old.id)).to be false
        expect(ChatMessage.exists?(recent.id)).to be true
      end
    end

    # TASK-033 TC-012: trust_index_histories NOT deleted
    context "preserves trust_index_histories" do
      it "does NOT delete old trust_index_histories" do
        old_ti = create(:trust_index_history,
          channel: channel, stream: stream,
          trust_index_score: 72.0, erv_percent: 72.0, ccv: 5000,
          confidence: 0.85, classification: "needs_review", cold_start_status: "full",
          signal_breakdown: {}, calculated_at: 91.days.ago)

        described_class.new.perform

        expect(TrustIndexHistory.exists?(old_ti.id)).to be true
      end
    end

    context "expired sessions" do
      let(:user) { create(:user) }

      it "deletes expired inactive sessions" do
        expired = Session.create!(
          user: user, token: SecureRandom.hex(32),
          expires_at: 1.day.ago, is_active: false
        )
        active = Session.create!(
          user: user, token: SecureRandom.hex(32),
          expires_at: 1.day.from_now, is_active: true
        )

        described_class.new.perform

        expect(Session.exists?(expired.id)).to be false
        expect(Session.exists?(active.id)).to be true
      end
    end
  end
end
