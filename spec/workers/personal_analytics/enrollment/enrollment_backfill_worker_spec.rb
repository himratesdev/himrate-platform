# frozen_string_literal: true

require "rails_helper"

RSpec.describe PersonalAnalytics::Enrollment::EnrollmentBackfillWorker do
  let(:user) { create(:user) }

  context "when :pva is enabled" do
    before do
      allow(Flipper).to receive(:enabled?).and_call_original
      allow(Flipper).to receive(:enabled?).with(:pva).and_return(true)
    end

    it "initiates state row + enqueues 2 child workers" do
      expect(PersonalAnalytics::Enrollment::HelixFollowsBackfillWorker).to receive(:perform_async).with(user.id)
      expect(PersonalAnalytics::Enrollment::GqlChannelShellBatchWorker).to receive(:perform_async).with(user.id)

      described_class.new.perform(user.id)

      state = PvaEnrollmentBackfillState.find_by(user_id: user.id)
      expect(state).to be_present
      expect(state.overall_status).to eq("pending")
    end

    it "skips child workers если state reused (recent completion <30d)" do
      PersonalAnalytics::Enrollment::StateStore.initiate(user_id: user.id)
      PvaEnrollmentBackfillState.find_by(user_id: user.id).update!(
        completed_at: 5.days.ago, overall_status: "done"
      )

      expect(PersonalAnalytics::Enrollment::HelixFollowsBackfillWorker).not_to receive(:perform_async)
      described_class.new.perform(user.id)
    end

    it "force=true bypasses skip-logic" do
      PersonalAnalytics::Enrollment::StateStore.initiate(user_id: user.id)
      PvaEnrollmentBackfillState.find_by(user_id: user.id).update!(
        completed_at: 5.days.ago, overall_status: "done"
      )

      expect(PersonalAnalytics::Enrollment::HelixFollowsBackfillWorker).to receive(:perform_async).with(user.id)
      # CR iter-4 N1: positional arg matching production perform_async contract (kwargs не
      # round-trip через Sidekiq JSON serialization).
      described_class.new.perform(user.id, true)
    end
  end

  context "when :pva is disabled" do
    before do
      allow(Flipper).to receive(:enabled?).and_call_original
      allow(Flipper).to receive(:enabled?).with(:pva).and_return(false)
    end

    it "is a no-op" do
      expect(PersonalAnalytics::Enrollment::HelixFollowsBackfillWorker).not_to receive(:perform_async)
      described_class.new.perform(user.id)
    end
  end
end
