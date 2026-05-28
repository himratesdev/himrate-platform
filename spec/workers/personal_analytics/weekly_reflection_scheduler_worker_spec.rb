# frozen_string_literal: true

require "rails_helper"

RSpec.describe PersonalAnalytics::WeeklyReflectionSchedulerWorker do
  let(:user_with_rollups) { create(:user) }
  let(:user_without) { create(:user) }

  before do
    allow(Flipper).to receive(:enabled?).and_call_original
    allow(Flipper).to receive(:enabled?).with(:pva).and_return(true)
    create(:pva_view_rollup, user: user_with_rollups)
    user_without # ensure created
  end

  it "fans out only to users with view rollups" do
    expect(PersonalAnalytics::WeeklyReflectionWorker).to receive(:perform_async).with(user_with_rollups.id).once
    expect(PersonalAnalytics::WeeklyReflectionWorker).not_to receive(:perform_async).with(user_without.id)

    described_class.new.perform
  end

  it "is a no-op when :pva is disabled" do
    allow(Flipper).to receive(:enabled?).with(:pva).and_return(false)

    expect(PersonalAnalytics::WeeklyReflectionWorker).not_to receive(:perform_async)
    described_class.new.perform
  end
end
