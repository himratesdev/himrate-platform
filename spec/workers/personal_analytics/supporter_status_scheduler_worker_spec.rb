# frozen_string_literal: true

require "rails_helper"

RSpec.describe PersonalAnalytics::SupporterStatusSchedulerWorker do
  let(:user) { create(:user) }

  it "fans out a per-user worker for each user with engagement/tenure data (:pva on)" do
    allow(Flipper).to receive(:enabled?).and_call_original
    allow(Flipper).to receive(:enabled?).with(:pva).and_return(true)
    create(:channel_tenure, user: user, twitch_channel_id: "555")

    expect(PersonalAnalytics::SupporterStatusWorker).to receive(:perform_async).with(user.id)

    described_class.new.perform
  end

  it "is a no-op when the :pva flag is disabled" do
    allow(Flipper).to receive(:enabled?).and_call_original
    allow(Flipper).to receive(:enabled?).with(:pva).and_return(false)
    create(:channel_tenure, user: user)

    expect(PersonalAnalytics::SupporterStatusWorker).not_to receive(:perform_async)

    described_class.new.perform
  end
end
