# frozen_string_literal: true

require "rails_helper"

RSpec.describe TrustIndex::Signals::AccountProfileScoring do
  let(:signal) { described_class.new }

  before do
    SignalConfiguration.find_or_create_by!(
      signal_type: "account_profile_scoring", category: "default", param_name: "weight_in_ti"
    ) { |c| c.param_value = 0.05 }
  end

  it "returns value based on % chatters with 3+ profile flags" do
    scores = [
      { components: { "profile_view_zero" => {}, "followers_zero" => {}, "description_null" => {} } },
      { components: { "profile_view_zero" => {}, "followers_zero" => {}, "banner_null" => {} } },
      { components: { "profile_view_zero" => {} } }, # only 1 flag — not suspicious
      { components: {} },
      { components: {} }
    ]
    result = signal.calculate(bot_scores: scores)
    # 2 out of 3 with profiles have >=3 flags, but 3/5 have profile data
    expect(result.value).to be > 0.0
    expect(result.metadata[:profile_suspicious]).to eq(2)
  end

  it "returns 0 when no chatters have 3+ flags" do
    scores = Array.new(10) { { components: { "profile_view_zero" => {} } } }
    result = signal.calculate(bot_scores: scores)
    expect(result.value).to eq(0.0)
  end

  it "returns nil for empty data" do
    result = signal.calculate(bot_scores: [])
    expect(result.value).to be_nil
  end

  it "returns nil when no profile data available" do
    scores = Array.new(10) { { components: { "cv_timing" => {} } } }
    result = signal.calculate(bot_scores: scores)
    expect(result.value).to be_nil
  end
end
