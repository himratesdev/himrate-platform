# frozen_string_literal: true

require "rails_helper"

RSpec.describe PersonalAnalytics::SupporterStatusWorker do
  let(:user) { create(:user) }

  context "when the :pva flag is enabled" do
    before do
      allow(Flipper).to receive(:enabled?).and_call_original
      allow(Flipper).to receive(:enabled?).with(:pva).and_return(true)
    end

    it "computes and upserts supporter status" do
      create(:channel_tenure, user: user, twitch_channel_id: "555", months: 10) # 20 → loyal

      described_class.new.perform(user.id)

      expect(PvaSupporterStatus.find_by(user_id: user.id, twitch_channel_id: "555").tier).to eq("loyal")
    end
  end

  context "when the :pva flag is disabled" do
    before do
      allow(Flipper).to receive(:enabled?).and_call_original
      allow(Flipper).to receive(:enabled?).with(:pva).and_return(false)
    end

    it "is a no-op" do
      create(:channel_tenure, user: user, twitch_channel_id: "555", months: 10)

      described_class.new.perform(user.id)

      expect(PvaSupporterStatus.where(user_id: user.id)).to be_empty
    end
  end
end
