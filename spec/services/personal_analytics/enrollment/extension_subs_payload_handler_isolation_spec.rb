# frozen_string_literal: true

require "rails_helper"

# CR iter-2 N4: regression guard для CR iter-1 S5 fix (ArgumentError isolation —
# не должно вызывать StateStore.update_source с nil source_key).
RSpec.describe PersonalAnalytics::Enrollment::ExtensionSubsPayloadHandler do
  let(:user) { create(:user) }

  before { PersonalAnalytics::Enrollment::StateStore.initiate(user_id: user.id) }

  describe ".call invalid source — ArgumentError isolation" do
    it "raises ArgumentError without calling StateStore.update_source" do
      expect(PersonalAnalytics::Enrollment::StateStore).not_to receive(:update_source)
      expect {
        described_class.call(user_id: user.id, payload: { "source" => 99, "subscriptions" => [] })
      }.to raise_error(ArgumentError, /invalid source/)
    end
  end

  describe ".call malformed anniversary_at (CR iter-2 S1 regression guard)" do
    it "isolates Date::Error per-row, other rows succeed, state stays consistent" do
      payload = {
        "source" => 5,
        "subscriptions" => [
          { "channel_twitch_id" => "1", "channel_login" => "good", "tier" => "1000",
            "cumulative_months" => 5 },
          { "channel_twitch_id" => "2", "channel_login" => "bad", "tier" => "1000",
            "cumulative_months" => 3, "anniversary_at" => "not-a-date" }
        ]
      }
      result = described_class.call(user_id: user.id, payload: payload)
      # First row upserts ok; second row swallowed Date::Error → false → 0 для second.
      expect(result.rows_affected).to eq(1)
      expect(result.error_class).to be_nil
      # Source state recorded done, not stuck in_progress.
      state = PvaEnrollmentBackfillState.find_by(user_id: user.id)
      expect(state.sources["source_5"]["status"]).to eq("done")
    end
  end
end
