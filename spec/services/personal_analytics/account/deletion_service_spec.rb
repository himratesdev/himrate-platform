# frozen_string_literal: true

require "rails_helper"

RSpec.describe PersonalAnalytics::Account::DeletionService do
  let(:user) { create(:user) }

  it "soft-deletes the user (sets deleted_at) + revokes sessions + appends consent_log" do
    Session.create!(user: user, token: SecureRandom.hex(16), expires_at: 1.day.from_now)
    create(:pva_view_rollup, user: user) # PVA data НЕ удаляется (PO directive)

    described_class.call(user)

    expect(user.reload.deleted_at).to be_within(2.seconds).of(Time.current)
    expect(Session.where(user_id: user.id).count).to eq(0)
    expect(PvaViewRollup.where(user_id: user.id).count).to eq(1) # данные сохранены
    expect(UserPrivacySetting.find_by(user_id: user.id).consent_log.last["action"]).to eq("account_deleted")
  end

  it "is idempotent — second call doesn't duplicate consent_log entry" do
    described_class.call(user)
    log_after_first = UserPrivacySetting.find_by(user_id: user.id).consent_log.dup

    described_class.call(user.reload)

    expect(UserPrivacySetting.find_by(user_id: user.id).consent_log).to eq(log_after_first)
  end

  it "removes the user from User.active scope (next authenticate_user! → 401)" do
    described_class.call(user)
    expect(User.active.find_by(id: user.id)).to be_nil
    expect(User.find_by(id: user.id)).to be_present # row сохранён, только deleted_at
  end
end
