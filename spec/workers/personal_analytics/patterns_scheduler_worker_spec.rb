# frozen_string_literal: true

require "rails_helper"

RSpec.describe PersonalAnalytics::PatternsSchedulerWorker do
  let(:user_with_rollups) { create(:user) }
  let(:user_old_only) { create(:user) } # rollup'ы > 60 дней — не кандидат
  let(:user_without) { create(:user) }

  before do
    allow(Flipper).to receive(:enabled?).and_call_original
    allow(Flipper).to receive(:enabled?).with(:pva).and_return(true)
    create(:pva_view_rollup, user: user_with_rollups, date: 10.days.ago.to_date)
    create(:pva_view_rollup, user: user_old_only, date: 120.days.ago.to_date)
    user_without # ensure created
  end

  it "fans out only to users with rollups in the last 60 days" do
    expect(PersonalAnalytics::PatternsWorker).to receive(:perform_async).with(user_with_rollups.id).once
    expect(PersonalAnalytics::PatternsWorker).not_to receive(:perform_async).with(user_old_only.id)
    expect(PersonalAnalytics::PatternsWorker).not_to receive(:perform_async).with(user_without.id)

    described_class.new.perform
  end

  it "is a no-op when :pva is disabled" do
    allow(Flipper).to receive(:enabled?).with(:pva).and_return(false)
    expect(PersonalAnalytics::PatternsWorker).not_to receive(:perform_async)
    described_class.new.perform
  end
end
