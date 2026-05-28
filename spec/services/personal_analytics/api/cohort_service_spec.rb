# frozen_string_literal: true

require "rails_helper"

RSpec.describe PersonalAnalytics::Api::CohortService do
  let(:user) { create(:user) }

  it "returns cold payload when there is no cohort row (edge #7)" do
    result = described_class.new(user: user).call

    expect(result.dig(:data, :suggestions)).to eq([])
    expect(result.dig(:data, :cohort_method)).to be_nil
    expect(result.dig(:meta, :cold_start)).to be(true)
  end

  it "returns suggestions + cohort_method when a row exists" do
    create(:pva_cohort, user: user,
      suggestions: [ { "login" => "hasanabi", "display_name" => "HasanAbi", "pct" => 73 } ],
      cohort_method: "co_watch")

    result = described_class.new(user: user).call

    expect(result.dig(:data, :cohort_method)).to eq("co_watch")
    expect(result.dig(:data, :suggestions).first["login"]).to eq("hasanabi")
    expect(result.dig(:meta, :cold_start)).to be(false)
  end
end
