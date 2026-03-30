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

  def make_config(attrs = {})
    defaults = {
      phone_verification_required: false, email_verification_required: false,
      followers_only_duration_min: nil, minimum_account_age_minutes: 0,
      subs_only_enabled: false, slow_mode_seconds: 0,
      restrict_first_time_chatters: false, last_checked_at: Time.current
    }
    OpenStruct.new(defaults.merge(attrs))
  end

  it "returns CPS=100, signal=0.0 for all protections ON" do
    config = make_config(
      phone_verification_required: true, email_verification_required: true,
      followers_only_duration_min: 30, minimum_account_age_minutes: 1500,
      subs_only_enabled: true, slow_mode_seconds: 60,
      restrict_first_time_chatters: true
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
  end

  it "calculates partial CPS correctly" do
    config = make_config(phone_verification_required: true, email_verification_required: true)
    result = signal.calculate(channel_protection_config: config)
    expect(result.metadata[:cps]).to eq(45) # 25 + 20
    expect(result.value).to be_within(0.01).of(0.55)
  end

  it "returns confidence=0.5 for stale config" do
    config = make_config(last_checked_at: 2.hours.ago)
    result = signal.calculate(channel_protection_config: config)
    expect(result.confidence).to eq(0.5)
  end
end
