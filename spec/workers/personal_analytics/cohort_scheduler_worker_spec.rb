# frozen_string_literal: true

require "rails_helper"

RSpec.describe PersonalAnalytics::CohortSchedulerWorker do
  let(:twitch_user) { create(:user) }
  let(:google_only) { create(:user) }

  before do
    allow(Flipper).to receive(:enabled?).and_call_original
    allow(Flipper).to receive(:enabled?).with(:pva).and_return(true)
    create(:auth_provider, user: twitch_user, provider: "twitch", provider_id: "111")
    google_only # ensure created без twitch provider
  end

  it "fans out only to users with a Twitch auth provider" do
    expect(PersonalAnalytics::CohortWorker).to receive(:perform_async).with(twitch_user.id).once
    expect(PersonalAnalytics::CohortWorker).not_to receive(:perform_async).with(google_only.id)

    described_class.new.perform
  end

  it "is a no-op when :pva is disabled" do
    allow(Flipper).to receive(:enabled?).with(:pva).and_return(false)
    expect(PersonalAnalytics::CohortWorker).not_to receive(:perform_async)
    described_class.new.perform
  end
end
