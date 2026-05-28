# frozen_string_literal: true

require "rails_helper"

RSpec.describe PersonalAnalytics::Privacy::UpdateService do
  let(:user) { create(:user) }

  it "creates a UserPrivacySetting row on first call + appends consent_log entry" do
    described_class.new(user: user, toggles: { display_name_visible: true }).call

    setting = UserPrivacySetting.find_by(user_id: user.id)
    expect(setting.display_name_visible).to be(true)
    expect(setting.recognition).to be(true) # DB default
    expect(setting.consent_log.size).to eq(1)
    expect(setting.consent_log.first["action"]).to eq("toggles_updated")
    expect(setting.consent_log.first["changes"]["display_name_visible"]).to include("from" => false, "to" => true)
  end

  it "is idempotent — no-op if values unchanged (no consent_log append)" do
    setting = create(:user_privacy_setting, user: user, display_name_visible: false, recognition: true)
    consent_before = setting.consent_log.dup

    described_class.new(user: user, toggles: { display_name_visible: false, recognition: true }).call

    expect(setting.reload.consent_log).to eq(consent_before)
  end

  it "appends only changed toggles to consent_log (diff only)" do
    create(:user_privacy_setting, user: user, display_name_visible: false, chat_capture: true)

    described_class.new(user: user, toggles: { display_name_visible: true, chat_capture: true }).call

    setting = UserPrivacySetting.find_by(user_id: user.id)
    expect(setting.consent_log.size).to eq(1)
    changes = setting.consent_log.first["changes"]
    expect(changes.keys).to eq([ "display_name_visible" ]) # chat_capture не изменился — не в diff
  end

  it "casts string booleans ('true'/'1') correctly" do
    described_class.new(user: user, toggles: { "recognition" => "false" }).call

    expect(UserPrivacySetting.find_by(user_id: user.id).recognition).to be(false)
  end

  it "raises InvalidToggles for empty / non-whitelisted input" do
    expect { described_class.new(user: user, toggles: {}).call }
      .to raise_error(described_class::InvalidToggles)
    expect { described_class.new(user: user, toggles: { malicious: true }).call }
      .to raise_error(described_class::InvalidToggles)
    expect { described_class.new(user: user, toggles: nil).call }
      .to raise_error(described_class::InvalidToggles)
  end

  it "concurrency: parallel updates don't violate UNIQUE on user_id (create_or_find_by)" do
    # First call creates the row
    described_class.new(user: user, toggles: { recognition: false }).call
    # Second call must find existing (no race even if UNIQUE was hit)
    expect do
      described_class.new(user: user, toggles: { chat_capture: false }).call
    end.not_to raise_error
    expect(UserPrivacySetting.where(user_id: user.id).count).to eq(1)
  end
end
