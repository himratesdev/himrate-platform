# frozen_string_literal: true

require "rails_helper"

RSpec.describe PersonalAnalytics::ViewAggregationWorker do
  let(:user) { create(:user) }

  def stream_view_event
    payload = { channel_id: "555", watched_at: Time.utc(2026, 5, 20, 20, 0, 0).iso8601, duration_sec: 600 }
    create(:sync_event, user: user, event_type: "stream_view", payload: payload, synced_at: Time.utc(2026, 5, 20, 20))
  end

  context "when the :pva flag is enabled" do
    before do
      allow(Flipper).to receive(:enabled?).and_call_original
      allow(Flipper).to receive(:enabled?).with(:pva).and_return(true)
    end

    it "ETLs stream_view events and builds the rollup end-to-end" do
      stream_view_event

      described_class.new.perform(user.id)

      expect(PvaViewEvent.where(user_id: user.id).count).to eq(1)
      rollup = PvaViewRollup.find_by(user_id: user.id, twitch_channel_id: "555")
      expect(rollup.total_seconds).to eq(600)
    end
  end

  context "when the :pva flag is disabled" do
    before do
      allow(Flipper).to receive(:enabled?).and_call_original
      allow(Flipper).to receive(:enabled?).with(:pva).and_return(false)
    end

    it "is a no-op" do
      stream_view_event

      described_class.new.perform(user.id)

      expect(PvaViewEvent.where(user_id: user.id)).to be_empty
      expect(PvaViewRollup.where(user_id: user.id)).to be_empty
    end
  end
end
