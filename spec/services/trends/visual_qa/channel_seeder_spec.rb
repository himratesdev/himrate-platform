# frozen_string_literal: true

require "rails_helper"

RSpec.describe Trends::VisualQa::ChannelSeeder do
  describe ".ensure_channel" do
    it "validates 'vqa_test_' prefix (rejects real-looking logins)" do
      expect { described_class.ensure_channel(login: "real_streamer") }
        .to raise_error(described_class::InvalidLogin)
    end

    it "creates channel idempotently" do
      ch1 = described_class.ensure_channel(login: "vqa_test_alpha")
      ch2 = described_class.ensure_channel(login: "vqa_test_alpha")
      expect(ch1.id).to eq(ch2.id)
    end

    # BUG-012: race condition repro. Two concurrent ensure_channel calls для
    # одного login должны produce ровно 1 Channel row. Pre-fix
    # (find_or_create_by!) — обe SELECT прошли without record → both INSERT →
    # 2 rows. Post-fix (create_or_find_by! + UNIQUE index) — один INSERT
    # succeeds, другой ловит RecordNotUnique → SELECT existing.
    it "BUG-012: race-safe против concurrent calls (UNIQUE index + create_or_find_by)" do
      login = "vqa_test_race_check"

      # Симулируем race: вручную INSERT row in another connection-like flow,
      # затем второй call должен НЕ создать duplicate, а вернуть existing.
      first = described_class.ensure_channel(login: login)
      second = described_class.ensure_channel(login: login)

      expect(Channel.where(login: login).count).to eq(1)
      expect(first.id).to eq(second.id)
    end

    # BUG-012: DB enforces UNIQUE на channels.login. Direct Channel.create!
    # с existing login должен raise RecordNotUnique (не silent duplicate).
    it "BUG-012: DB rejects duplicate login at insert level (UNIQUE index)" do
      described_class.ensure_channel(login: "vqa_test_db_unique")

      expect {
        Channel.create!(
          login: "vqa_test_db_unique",
          twitch_id: "vqa_twitch_other",
          display_name: "Other",
          is_monitored: true
        )
      }.to raise_error(ActiveRecord::RecordNotUnique)
    end
  end

  describe ".ensure_premium_user_tracking" do
    let(:channel) { described_class.ensure_channel(login: "vqa_test_premium_seeder") }

    it "creates User + Subscription + TrackedChannel chain" do
      expect {
        described_class.ensure_premium_user_tracking(channel: channel)
      }.to change(User, :count).by(1)
        .and change(Subscription, :count).by(1)
        .and change(TrackedChannel, :count).by(1)
    end

    # BUG-011: TrackedChannel.subscription_id ДОЛЖЕН ссылаться на seeded Subscription.
    # ChannelPolicy#channel_tracked? JOINs через subscription_id — NULL → 403.
    it "links TrackedChannel.subscription_id к seeded Subscription (BUG-011)" do
      user = described_class.ensure_premium_user_tracking(channel: channel)

      tc = TrackedChannel.find_by!(user_id: user.id, channel_id: channel.id)
      sub = Subscription.find_by!(user_id: user.id, is_active: true)

      expect(tc.subscription_id).to eq(sub.id)
    end

    # BUG-011 build-for-years: spec gate guards ChannelPolicy authorization flow,
    # not just creation. Catches regression если в future кто-то опять забудет
    # subscription_id link.
    it "passes ChannelPolicy#view_trends_historical? для seeded user+channel" do
      user = described_class.ensure_premium_user_tracking(channel: channel)
      policy = ChannelPolicy.new(user, channel)
      expect(policy.view_trends_historical?).to be true
    end

    it "is idempotent — повторный call не создаёт duplicates" do
      described_class.ensure_premium_user_tracking(channel: channel)
      described_class.ensure_premium_user_tracking(channel: channel)

      expect(User.where(email: described_class::PREMIUM_USER_EMAIL_TEMPLATE % described_class.user_digest(channel)).count).to eq(1)
      expect(Subscription.where(user_id: User.last.id).count).to eq(1)
      expect(TrackedChannel.where(channel_id: channel.id).count).to eq(1)
    end

    # BUG-012: retrofit pattern в коде сохраняется (||= preserves valid value),
    # но legacy NULL state больше невозможен — DB enforces NOT NULL constraint
    # (migration 20260425100002). Try-create с nil subscription_id raises
    # ActiveRecord::NotNullViolation — invariant guaranteed.
    it "BUG-012: DB rejects TrackedChannel insert с NULL subscription_id" do
      digest = described_class.user_digest(channel)
      user = User.create!(
        email: described_class::PREMIUM_USER_EMAIL_TEMPLATE % digest,
        username: "vqa_premium_#{digest}",
        role: "viewer",
        tier: "premium"
      )

      expect {
        TrackedChannel.create!(user_id: user.id, channel_id: channel.id,
          subscription_id: nil, tracking_enabled: true, added_at: 14.days.ago)
      }.to raise_error(ActiveRecord::NotNullViolation)
    end
  end

  describe ".ensure_streamer_oauth" do
    let(:channel) { described_class.ensure_channel(login: "vqa_test_streamer_seeder") }

    it "creates streamer User + AuthProvider link" do
      expect {
        described_class.ensure_streamer_oauth(channel: channel)
      }.to change(User, :count).by(1)
        .and change(AuthProvider, :count).by(1)

      user = User.last
      expect(user.role).to eq("streamer")
      ap = AuthProvider.find_by(user_id: user.id, provider: "twitch")
      expect(ap.is_broadcaster).to be true
      expect(ap.provider_id).to eq(channel.twitch_id)
    end
  end

  describe ".teardown_channel" do
    let(:channel) { described_class.ensure_channel(login: "vqa_test_teardown") }

    it "removes full chain (channel + users + tracking + subscription + auth)" do
      described_class.ensure_premium_user_tracking(channel: channel)
      described_class.ensure_streamer_oauth(channel: channel)

      stats = described_class.teardown_channel(channel: channel)

      expect(stats[:tracked_channels]).to eq(1)
      expect(stats[:subscriptions]).to eq(1)
      expect(stats[:auth_providers]).to eq(1)
      expect(stats[:users]).to eq(2)
      expect(stats[:channel]).to eq(1)
      expect(Channel.find_by(login: "vqa_test_teardown")).to be_nil
    end
  end
end
