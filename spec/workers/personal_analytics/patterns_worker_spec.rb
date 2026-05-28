# frozen_string_literal: true

require "rails_helper"

RSpec.describe PersonalAnalytics::PatternsWorker do
  let(:user) { create(:user, locale: "ru") }

  before do
    # Fill enough rollups so builder doesn't no-op.
    28.times do |d|
      create(:pva_view_rollup, user: user, date: Date.current - d, total_seconds: 1800,
        hour_histogram: { "20" => 1800 })
    end
  end

  context "when :pva is enabled" do
    before do
      allow(Flipper).to receive(:enabled?).and_call_original
      allow(Flipper).to receive(:enabled?).with(:pva).and_return(true)
    end

    it "delegates to PatternsBuilder" do
      expect(PersonalAnalytics::Patterns::PatternsBuilder).to receive(:call).with(user.id)
      described_class.new.perform(user.id)
    end
  end

  context "when :pva is disabled" do
    before do
      allow(Flipper).to receive(:enabled?).and_call_original
      allow(Flipper).to receive(:enabled?).with(:pva).and_return(false)
    end

    it "is a no-op" do
      expect(PersonalAnalytics::Patterns::PatternsBuilder).not_to receive(:call)
      described_class.new.perform(user.id)
    end
  end
end
