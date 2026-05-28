# frozen_string_literal: true

require "rails_helper"

RSpec.describe PvaEnrollmentBackfillState do
  let(:user) { create(:user) }

  subject(:state) do
    described_class.new(user: user, oauth_linked_at: Time.current, overall_status: "pending")
  end

  describe "validations" do
    it "is valid with required attributes" do
      expect(state).to be_valid
    end

    it "rejects invalid overall_status" do
      state.overall_status = "invalid"
      expect(state).not_to be_valid
    end

    it "enforces user_id uniqueness" do
      state.save!
      duplicate = described_class.new(user: user, oauth_linked_at: Time.current, overall_status: "pending")
      expect(duplicate).not_to be_valid
    end
  end

  describe "#recent_completion?" do
    it "returns false когда completed_at is nil" do
      state.completed_at = nil
      expect(state.recent_completion?).to be false
    end

    it "returns true when overall_status=done + completed within 30 days" do
      state.overall_status = "done"
      state.completed_at = 5.days.ago
      expect(state.recent_completion?).to be true
    end

    it "returns false when failed/partial (CR iter-4 N2 defense-in-depth)" do
      state.overall_status = "partial"
      state.completed_at = 5.days.ago
      expect(state.recent_completion?).to be false
    end

    it "returns false when completed > 30 days ago" do
      state.overall_status = "done"
      state.completed_at = 31.days.ago
      expect(state.recent_completion?).to be false
    end
  end

  describe "scopes" do
    it "stuck returns records past threshold" do
      state.oauth_linked_at = 15.minutes.ago
      state.overall_status = "in_progress"
      state.save!

      expect(described_class.stuck(10.minutes.ago)).to include(state)
    end

    it "stuck excludes terminal-status records" do
      state.oauth_linked_at = 15.minutes.ago
      state.overall_status = "done"
      state.save!

      expect(described_class.stuck(10.minutes.ago)).not_to include(state)
    end
  end
end
