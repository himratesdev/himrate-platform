# frozen_string_literal: true

require "rails_helper"

RSpec.describe PersonalAnalytics::Api::PrivacyService do
  let(:user) { create(:user) }

  it "returns DEFAULTS + empty consent_log when no row exists (cold)" do
    result = described_class.new(user: user).call

    expect(result.dig(:data, :toggles)).to eq(described_class::DEFAULTS)
    expect(result.dig(:data, :consent_log)).to eq([])
    expect(result.dig(:meta, :cold_start)).to be(true)
  end

  it "returns stored toggles + consent_log when a row exists" do
    create(:user_privacy_setting, user: user, display_name_visible: true, chat_capture: false,
      consent_log: [ { "action" => "toggles_updated", "changed_at" => "2026-05-28T00:00:00Z" } ])

    result = described_class.new(user: user).call

    expect(result.dig(:data, :toggles, :display_name_visible)).to be(true)
    expect(result.dig(:data, :toggles, :chat_capture)).to be(false)
    expect(result.dig(:data, :toggles, :recognition)).to be(true)
    expect(result.dig(:data, :consent_log).first["action"]).to eq("toggles_updated")
    expect(result.dig(:meta, :cold_start)).to be(false)
  end
end
