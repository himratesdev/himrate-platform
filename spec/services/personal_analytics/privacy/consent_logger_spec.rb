# frozen_string_literal: true

require "rails_helper"

RSpec.describe PersonalAnalytics::Privacy::ConsentLogger do
  let(:user) { create(:user) }

  it "creates UserPrivacySetting if absent + appends entry" do
    described_class.log!(user, action: "export_completed", job_id: "abc-123")

    setting = UserPrivacySetting.find_by(user_id: user.id)
    expect(setting).to be_present
    expect(setting.consent_log.size).to eq(1)
    expect(setting.consent_log.first).to include("action" => "export_completed", "job_id" => "abc-123")
    expect(setting.consent_log.first["at"]).to match(/\A20\d{2}-\d{2}-\d{2}T/)
  end

  it "preserves existing consent_log entries + appends new" do
    create(:user_privacy_setting, user: user,
      consent_log: [ { "action" => "toggles_updated", "at" => "2026-05-01T00:00:00Z" } ])

    described_class.log!(user, action: "account_deleted")

    log = UserPrivacySetting.find_by(user_id: user.id).consent_log
    expect(log.map { |e| e["action"] }).to eq([ "toggles_updated", "account_deleted" ])
  end
end
