# frozen_string_literal: true

require "rails_helper"

RSpec.describe TrustIndex::Signals::AccountProfileScoring do
  let(:signal) { described_class.new }

  before do
    SignalConfiguration.find_or_create_by!(
      signal_type: "account_profile_scoring", category: "default", param_name: "weight_in_ti"
    ) { |c| c.param_value = 0.05 }
  end

  # TASK-251.W2b: denominator = chatters whose profile was fetched (have "profile_present");
  # numerator = those with >=3 genuine bot-account flags. Clean profiled viewers (0 flags) count
  # in the denominator, not as suspicious.
  it "is suspicious-count over ALL profiled chatters (clean viewers included in denominator)" do
    # TASK-251.20: profile_view_zero dropped (Twitch deprecated profileViewCount).
    scores = [
      { components: { "profile_present" => {}, "followers_zero" => {}, "account_age_7d" => {}, "follows_zero" => {} } }, # 3 flags → suspicious
      { components: { "profile_present" => {}, "followers_zero" => {}, "account_age_30d" => {}, "follows_excessive" => {} } }, # 3 flags → suspicious
      { components: { "profile_present" => {}, "followers_zero" => {} } },  # 1 flag → not
      { components: { "profile_present" => {} } },                          # clean profiled viewer → denom only
      { components: { "profile_present" => {} } }                           # clean profiled viewer → denom only
    ]
    result = signal.calculate(bot_scores: scores)
    expect(result.metadata[:profile_suspicious]).to eq(2)
    expect(result.metadata[:total_with_profiles]).to eq(5)
    expect(result.value).to eq(2.0 / 5)
  end

  it "does NOT flag normal viewers lacking streamer presence (no description/banner/videos flags exist)" do
    # A real viewer: profiled, old account, has followers, follows channels → zero bot flags.
    scores = Array.new(8) { { components: { "profile_present" => {} } } }
    result = signal.calculate(bot_scores: scores)
    expect(result.value).to eq(0.0)
    expect(result.metadata[:total_with_profiles]).to eq(8)
  end

  it "returns 0 when no profiled chatter has 3+ flags" do
    # TASK-251.20: profile_view_zero dropped (Twitch deprecated profileViewCount).
    scores = Array.new(10) { { components: { "profile_present" => {}, "followers_zero" => {} } } }
    result = signal.calculate(bot_scores: scores)
    expect(result.value).to eq(0.0)
  end

  it "returns nil for empty data" do
    expect(signal.calculate(bot_scores: []).value).to be_nil
  end

  it "returns nil when no chatter has a fetched profile (no profile_present marker)" do
    # Flags without the marker (e.g. only chat-behaviour components) → not counted as 'profiled'.
    scores = Array.new(10) { { components: { "cv_timing" => {}, "followers_zero" => {} } } }
    result = signal.calculate(bot_scores: scores)
    expect(result.value).to be_nil
  end
end
