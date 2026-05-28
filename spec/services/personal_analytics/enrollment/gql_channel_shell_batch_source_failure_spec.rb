# frozen_string_literal: true

require "rails_helper"

# CR iter-2 N4: regression guards for CR iter-1 M2 fix (all-batch-failure distinction).
RSpec.describe PersonalAnalytics::Enrollment::GqlChannelShellBatchSource do
  let(:user) { create(:user) }

  before { PersonalAnalytics::Enrollment::StateStore.initiate(user_id: user.id) }

  describe ".call all-batches-fail scenario (CR iter-1 M2 regression guard)" do
    it "reports failed when every batch returns nil from fetch_batch" do
      create(:pva_followed_channel, user: user, twitch_channel_id: "111",
        twitch_login: "alpha", followed_at: 1.year.ago)
      create(:pva_followed_channel, user: user, twitch_channel_id: "222",
        twitch_login: "beta", followed_at: 1.year.ago)

      # Stub Twitch::GqlClient#batch_persisted_queries to simulate all-batch transport failure.
      mock_client = instance_double(Twitch::GqlClient)
      allow(Twitch::GqlClient).to receive(:new).and_return(mock_client)
      allow(mock_client).to receive(:batch_persisted_queries).and_return(nil)

      result = described_class.call(user.id)
      expect(result.status).to eq("failed")
      expect(result.error_class).to eq("ChannelShellBatchFailed")
    end
  end
end
