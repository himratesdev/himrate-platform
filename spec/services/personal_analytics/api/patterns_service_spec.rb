# frozen_string_literal: true

require "rails_helper"

RSpec.describe PersonalAnalytics::Api::PatternsService do
  let(:user) { create(:user) }

  it "returns cold payload when there are no patterns" do
    result = described_class.new(user: user).call

    expect(result.dig(:data, :patterns)).to eq([])
    expect(result.dig(:meta, :cold_start)).to be(true)
  end

  it "returns all patterns ordered by computed_at DESC" do
    older = create(:pva_pattern, user: user, computed_at: 2.days.ago)
    newer = create(:pva_pattern, user: user, computed_at: 1.hour.ago)

    result = described_class.new(user: user).call

    ids = result.dig(:data, :patterns).map { |p| p[:id] }
    expect(ids).to eq([ newer.id, older.id ])
  end
end
