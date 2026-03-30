# frozen_string_literal: true

require "rails_helper"

RSpec.describe TrustIndex::Signals::CcvChatCorrelation do
  let(:signal) { described_class.new }

  before do
    SignalConfiguration.find_or_create_by!(
      signal_type: "ccv_chat_correlation", category: "default", param_name: "weight_in_ti"
    ) { |c| c.param_value = 0.07 }
  end

  it "detects divergence: CCV +50%, chat +2%" do
    ccv = [ { ccv: 500, timestamp: 10.minutes.ago }, { ccv: 750, timestamp: Time.current } ]
    chat = [ { msg_count: 100, timestamp: 10.minutes.ago }, { msg_count: 102, timestamp: Time.current } ]
    result = signal.calculate(ccv_series_10min: ccv, chat_rate_10min: chat)
    expect(result.value).to be > 0.0
  end

  it "returns 0 when both CCV and chat increase proportionally" do
    ccv = [ { ccv: 500, timestamp: 10.minutes.ago }, { ccv: 750, timestamp: Time.current } ]
    chat = [ { msg_count: 100, timestamp: 10.minutes.ago }, { msg_count: 160, timestamp: Time.current } ]
    result = signal.calculate(ccv_series_10min: ccv, chat_rate_10min: chat)
    expect(result.value).to eq(0.0)
  end

  it "returns 0 for CCV decrease (not bots — natural end-of-stream)" do
    ccv = [ { ccv: 1000, timestamp: 10.minutes.ago }, { ccv: 500, timestamp: Time.current } ]
    chat = [ { msg_count: 100, timestamp: 10.minutes.ago }, { msg_count: 100, timestamp: Time.current } ]
    result = signal.calculate(ccv_series_10min: ccv, chat_rate_10min: chat)
    expect(result.value).to eq(0.0)
    expect(result.metadata[:reason]).to eq("ccv_decrease")
  end

  it "returns nil for insufficient data" do
    result = signal.calculate(ccv_series_10min: [], chat_rate_10min: [])
    expect(result.value).to be_nil
  end

  it "returns nil for baseline zero" do
    ccv = [ { ccv: 0, timestamp: 10.minutes.ago }, { ccv: 500, timestamp: Time.current } ]
    chat = [ { msg_count: 0, timestamp: 10.minutes.ago }, { msg_count: 10, timestamp: Time.current } ]
    result = signal.calculate(ccv_series_10min: ccv, chat_rate_10min: chat)
    expect(result.value).to be_nil
  end
end
