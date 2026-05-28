# frozen_string_literal: true

require "rails_helper"

RSpec.describe PersonalAnalytics::Enrollment::EnrollmentBackfillSweepWorker do
  let(:user) { create(:user) }

  before do
    allow(Flipper).to receive(:enabled?).and_call_original
    allow(Flipper).to receive(:enabled?).with(:pva).and_return(true)
  end

  it "marks stuck enrollments как partial_timeout" do
    PersonalAnalytics::Enrollment::StateStore.initiate(user_id: user.id)
    state = PvaEnrollmentBackfillState.find_by(user_id: user.id)
    state.update!(oauth_linked_at: 15.minutes.ago, overall_status: "in_progress")

    described_class.new.perform

    state.reload
    expect(state.overall_status).to eq("partial_timeout")
  end

  it "skips fresh enrollments" do
    PersonalAnalytics::Enrollment::StateStore.initiate(user_id: user.id)
    described_class.new.perform

    state = PvaEnrollmentBackfillState.find_by(user_id: user.id)
    expect(state.overall_status).to eq("pending")
  end

  it "is a no-op когда :pva disabled" do
    allow(Flipper).to receive(:enabled?).with(:pva).and_return(false)
    PersonalAnalytics::Enrollment::StateStore.initiate(user_id: user.id)
    expect(PersonalAnalytics::Enrollment::StateStore).not_to receive(:mark_partial_timeout)
    described_class.new.perform
  end
end
