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
          signal_type: "account_age", value: 0.5
        )
        recent_signal = TiSignal.create!(
          stream: stream, timestamp: 1.day.ago,
          signal_type: "account_age", value: 0.8
        )

        described_class.new.perform

        expect(TiSignal.exists?(old_signal.id)).to be false
        expect(TiSignal.exists?(recent_signal.id)).to be true
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
