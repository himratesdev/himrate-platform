# frozen_string_literal: true

require "rails_helper"

RSpec.describe PersonalAnalytics::Enrollment::HelixFollowsBackfillWorker do
  let(:user) { create(:user) }

  context "when :pva is enabled" do
    before do
      allow(Flipper).to receive(:enabled?).and_call_original
      allow(Flipper).to receive(:enabled?).with(:pva).and_return(true)
    end

    it "delegates к HelixFollowsSource" do
      expect(PersonalAnalytics::Enrollment::HelixFollowsSource).to receive(:call).with(user.id)
      described_class.new.perform(user.id)
    end
  end

  context "when :pva is disabled" do
    before do
      allow(Flipper).to receive(:enabled?).and_call_original
      allow(Flipper).to receive(:enabled?).with(:pva).and_return(false)
    end

    it "is a no-op" do
      expect(PersonalAnalytics::Enrollment::HelixFollowsSource).not_to receive(:call)
      described_class.new.perform(user.id)
    end
  end
end
