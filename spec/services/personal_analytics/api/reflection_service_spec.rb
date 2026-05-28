# frozen_string_literal: true

require "rails_helper"

RSpec.describe PersonalAnalytics::Api::ReflectionService do
  let(:user) { create(:user) }
  let(:monday) { Date.new(2026, 5, 18) }

  it "returns the latest week when no ?week is given" do
    create(:pva_weekly_reflection, user: user, week_start: monday - 7, narrative: "old")
    create(:pva_weekly_reflection, user: user, week_start: monday, narrative: "latest")

    result = described_class.new(user: user).call

    expect(result.dig(:data, :reflection, :narrative)).to eq("latest")
    expect(result.dig(:meta, :cold_start)).to be(false)
  end

  it "returns the specified ?week (normalizing non-Monday to Monday)" do
    create(:pva_weekly_reflection, user: user, week_start: monday)
    result = described_class.new(user: user, week: (monday + 3).iso8601).call # Thu → Mon
    expect(result.dig(:data, :reflection, :week_start)).to eq(monday.iso8601)
  end

  it "returns cold payload (reflection: nil) when no row matches" do
    result = described_class.new(user: user, week: monday.iso8601).call

    expect(result.dig(:data, :reflection)).to be_nil
    expect(result.dig(:meta, :cold_start)).to be(true)
  end

  it "raises InvalidWeek for malformed ?week" do
    expect { described_class.new(user: user, week: "bogus").call }
      .to raise_error(PersonalAnalytics::Api::ReflectionService::InvalidWeek)
  end

  it "returns archive listing when ?archive=true" do
    create(:pva_weekly_reflection, user: user, week_start: monday - 7)
    create(:pva_weekly_reflection, user: user, week_start: monday)

    result = described_class.new(user: user, archive: "true").call

    weeks = result.dig(:data, :archive).map { |w| w[:week_start] }
    expect(weeks).to eq([ monday.iso8601, (monday - 7).iso8601 ])
  end
end
