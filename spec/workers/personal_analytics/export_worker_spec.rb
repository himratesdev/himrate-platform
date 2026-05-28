# frozen_string_literal: true

require "rails_helper"

RSpec.describe PersonalAnalytics::ExportWorker do
  let(:user) { create(:user) }
  let(:job_id) { SecureRandom.uuid }

  before do
    allow(Flipper).to receive(:enabled?).and_call_original
    allow(Flipper).to receive(:enabled?).with(:pva).and_return(true)
  end

  it "builds archive + writes to Rails.cache with TTL + appends consent_log" do
    create(:pva_view_rollup, user: user)

    described_class.new.perform(user.id, job_id)

    raw = Rails.cache.read(described_class.cache_key(job_id))
    expect(raw).to be_present
    parsed = JSON.parse(raw)
    expect(parsed["user"]["id"]).to eq(user.id)
    expect(parsed["analytics"]["view_rollups"].size).to eq(1)

    setting = UserPrivacySetting.find_by(user_id: user.id)
    expect(setting.consent_log.last).to include("action" => "export_completed", "job_id" => job_id)
  end

  it "no-ops when :pva is disabled" do
    allow(Flipper).to receive(:enabled?).with(:pva).and_return(false)

    described_class.new.perform(user.id, job_id)

    expect(Rails.cache.read(described_class.cache_key(job_id))).to be_nil
  end

  it "no-ops gracefully if user no longer exists (deleted between enqueue + run)" do
    expect { described_class.new.perform(SecureRandom.uuid, job_id) }.not_to raise_error
    expect(Rails.cache.read(described_class.cache_key(job_id))).to be_nil
  end
end
