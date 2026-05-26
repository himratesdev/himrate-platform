# frozen_string_literal: true

require "rails_helper"

RSpec.describe TrustIndex::Signals::AuthRatio do
  let(:signal) { described_class.new }

  before do
    SignalConfiguration.find_or_create_by!(
      signal_type: "auth_ratio", category: "default", param_name: "weight_in_ti"
    ) { |c| c.param_value = 0.15 }
  end

  # TASK-251.6: the "chatters present" count this signal needs (GQL chatters-list /
  # extension gql_data) is unavailable server-side; it abstains rather than misfire on
  # active-chatters data (which would false-flag every channel as view-botted).
  # Re-scope tracked in TASK-C1 / TASK-251.9.
  it "abstains (insufficient) — present-chatters count unavailable server-side" do
    result = signal.calculate(latest_ccv: 1000, category: "just_chatting")
    expect(result.value).to be_nil
    expect(result.confidence).to eq(0.0)
  end

  it "abstains regardless of how high CCV is" do
    result = signal.calculate(latest_ccv: 50_000, category: "default")
    expect(result.value).to be_nil
    expect(result.confidence).to eq(0.0)
  end

  it "reports no_ccv when CCV is absent" do
    result = signal.calculate(latest_ccv: 0, category: "default")
    expect(result.value).to be_nil
    expect(result.confidence).to eq(0.0)
  end

  it "reads weight from DB" do
    expect(signal.weight("default")).to eq(0.15)
  end
end
