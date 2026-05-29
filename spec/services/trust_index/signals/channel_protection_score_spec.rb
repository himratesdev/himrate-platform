# frozen_string_literal: true

require "rails_helper"
require "ostruct"

RSpec.describe TrustIndex::Signals::ChannelProtectionScore do
  let(:signal) { described_class.new }

  before do
    SignalConfiguration.find_or_create_by!(
      signal_type: "channel_protection_score", category: "default", param_name: "weight_in_ti"
    ) { |c| c.param_value = 0.05 }
  end

  # BUG-251.32: CPS components recalibrated for the post-schema-shift fields. Twitch removed
  # `Channel.accountVerificationOptions` type; verification now consolidated into a single
  # boolean `chatSettings.requireVerifiedAccount` → ChannelProtectionConfig#verified_account_required.
  # Legacy columns (email_verification_required / phone_verification_required /
  # minimum_account_age_minutes / restrict_first_time_chatters) are no longer scored —
  # historical rows untouched, new rows write the new boolean.
  def make_config(attrs = {})
    defaults = {
      verified_account_required: false,
      followers_only_duration_min: nil,
      subs_only_enabled: false,
      slow_mode_seconds: 0,
      emote_only_enabled: false,
      last_checked_at: Time.current
    }
    OpenStruct.new(defaults.merge(attrs))
  end

  it "returns CPS=100, signal=0.0 for all protections ON" do
    config = make_config(
      verified_account_required: true,  # 30
      followers_only_duration_min: 30,  # 30 (positive duration)
      subs_only_enabled: true,          # 20
      slow_mode_seconds: 60,            # 15
      emote_only_enabled: true          # 5
    )
    result = signal.calculate(channel_protection_config: config)
    expect(result.value).to eq(0.0)
    expect(result.metadata[:cps]).to eq(100)
  end

  it "returns CPS=0, signal=1.0 for no protections" do
    config = make_config
    result = signal.calculate(channel_protection_config: config)
    expect(result.value).to eq(1.0)
    expect(result.metadata[:cps]).to eq(0)
  end

  it "returns signal=1.0 with confidence=0.0 when no config" do
    result = signal.calculate(channel_protection_config: nil)
    expect(result.value).to eq(1.0)
    expect(result.confidence).to eq(0.0)
    expect(result.metadata[:reason]).to eq("no_config")
  end

  describe "individual component scoring" do
    it "verified_account_required contributes 30 pts" do
      result = signal.calculate(channel_protection_config: make_config(verified_account_required: true))
      expect(result.metadata[:cps]).to eq(30)
    end

    it "followers_only_duration_min = 0 contributes 15 pts (any-duration FO)" do
      result = signal.calculate(channel_protection_config: make_config(followers_only_duration_min: 0))
      expect(result.metadata[:cps]).to eq(15)
    end

    it "followers_only_duration_min > 0 contributes 30 pts (stricter FO)" do
      result = signal.calculate(channel_protection_config: make_config(followers_only_duration_min: 60))
      expect(result.metadata[:cps]).to eq(30)
    end

    # CR-iter1 Suggestion-5: Twitch returns -1 when follower-only mode is OFF (sentinel value,
    # not nil). Ensure the < 0 guard short-circuits to 0 pts.
    it "followers_only_duration_min = -1 (Twitch OFF sentinel) contributes 0 pts" do
      result = signal.calculate(channel_protection_config: make_config(followers_only_duration_min: -1))
      expect(result.metadata[:cps]).to eq(0)
    end

    it "subs_only_enabled contributes 20 pts" do
      result = signal.calculate(channel_protection_config: make_config(subs_only_enabled: true))
      expect(result.metadata[:cps]).to eq(20)
    end

    it "slow_mode tiers: 0/5/10/15 for 0/1-10/11-30/31+ seconds" do
      expect(signal.calculate(channel_protection_config: make_config(slow_mode_seconds: 0)).metadata[:cps]).to eq(0)
      expect(signal.calculate(channel_protection_config: make_config(slow_mode_seconds: 5)).metadata[:cps]).to eq(5)
      expect(signal.calculate(channel_protection_config: make_config(slow_mode_seconds: 20)).metadata[:cps]).to eq(10)
      expect(signal.calculate(channel_protection_config: make_config(slow_mode_seconds: 60)).metadata[:cps]).to eq(15)
    end

    it "emote_only_enabled contributes 5 pts" do
      result = signal.calculate(channel_protection_config: make_config(emote_only_enabled: true))
      expect(result.metadata[:cps]).to eq(5)
    end
  end

  it "calculates partial CPS correctly (verified + slow_mode 60s)" do
    config = make_config(verified_account_required: true, slow_mode_seconds: 60)
    result = signal.calculate(channel_protection_config: config)
    expect(result.metadata[:cps]).to eq(45) # 30 + 15
    expect(result.value).to be_within(0.01).of(0.55)
  end

  it "returns confidence=0.5 for stale config (>1h old)" do
    config = make_config(last_checked_at: 2.hours.ago, verified_account_required: true)
    result = signal.calculate(channel_protection_config: config)
    expect(result.confidence).to eq(0.5)
  end

  it "returns confidence=1.0 for fresh config (<1h old)" do
    config = make_config(last_checked_at: 10.minutes.ago, verified_account_required: true)
    result = signal.calculate(channel_protection_config: config)
    expect(result.confidence).to eq(1.0)
  end

  describe "breakdown metadata" do
    it "returns the 5 post-BUG-251.32 components only (drops legacy fields)" do
      config = make_config(verified_account_required: true, subs_only_enabled: true)
      result = signal.calculate(channel_protection_config: config)
      expect(result.metadata[:components].keys).to contain_exactly(
        :verified_account_required, :followers_only, :subs_only, :slow_mode, :emote_only
      )
      expect(result.metadata[:components][:verified_account_required]).to be true
    end
  end
end
