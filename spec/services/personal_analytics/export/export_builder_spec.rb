# frozen_string_literal: true

require "rails_helper"

RSpec.describe PersonalAnalytics::Export::ExportBuilder do
  let(:user) { create(:user, locale: "ru") }

  it "returns nil for unknown user_id" do
    expect(described_class.call(SecureRandom.uuid)).to be_nil
  end

  it "collects all PVA tables + user + privacy into one hash" do
    create(:pva_view_rollup, user: user)
    create(:pva_engagement_event, user: user)
    create(:pva_chat_activity, user: user)
    create(:channel_tenure, user: user)
    create(:pva_supporter_status, user: user)
    create(:pva_weekly_reflection, user: user)
    create(:pva_pattern, user: user)
    create(:pva_cohort, user: user, suggestions: [ { "login" => "x", "pct" => 80 } ])
    create(:user_privacy_setting, user: user, recognition: false,
      consent_log: [ { "action" => "toggles_updated", "at" => "2026-05-01T00:00:00Z" } ])

    archive = described_class.call(user.id)

    expect(archive[:schema_version]).to eq(1)
    expect(archive[:user][:id]).to eq(user.id)
    expect(archive[:user][:twitch_login]).to eq(user.username)
    expect(archive[:analytics][:view_rollups].size).to eq(1)
    expect(archive[:analytics][:engagement_events].size).to eq(1)
    expect(archive[:analytics][:chat_activities].size).to eq(1)
    expect(archive[:analytics][:channel_tenures].size).to eq(1)
    expect(archive[:analytics][:supporter_statuses].size).to eq(1)
    expect(archive[:analytics][:weekly_reflections].size).to eq(1)
    expect(archive[:analytics][:patterns].size).to eq(1)
    expect(archive[:analytics][:cohort]).to be_present
    expect(archive[:privacy][:toggles]["recognition"]).to be(false)
    expect(archive[:privacy][:consent_log].size).to eq(1)
  end

  it "returns empty privacy when no UserPrivacySetting exists" do
    archive = described_class.call(user.id)
    expect(archive[:privacy]).to eq(toggles: nil, consent_log: [])
  end

  it "scope is per-user (does NOT include other users' data)" do
    other = create(:user)
    create(:pva_view_rollup, user: other)
    create(:pva_view_rollup, user: user)

    archive = described_class.call(user.id)

    expect(archive[:analytics][:view_rollups].size).to eq(1)
    expect(archive[:analytics][:view_rollups].first["user_id"]).to eq(user.id)
  end
end
