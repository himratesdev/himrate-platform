# frozen_string_literal: true

require "rails_helper"

RSpec.describe AuthEvent, type: :model do
  it { is_expected.to belong_to(:user).optional }

  describe "validations" do
    it { is_expected.to validate_presence_of(:provider) }
    it { is_expected.to validate_presence_of(:result) }

    it "validates provider inclusion" do
      event = build(:auth_event, provider: "invalid")
      expect(event).not_to be_valid
    end

    it "validates result inclusion" do
      event = build(:auth_event, result: "invalid")
      expect(event).not_to be_valid
    end

    it "allows valid providers" do
      AuthEvent::PROVIDERS.each do |p|
        expect(build(:auth_event, provider: p)).to be_valid
      end
    end

    it "allows valid results" do
      AuthEvent::RESULTS.each do |r|
        expect(build(:auth_event, result: r)).to be_valid
      end
    end
  end

  describe "scopes" do
    it ".failures returns only failures" do
      create(:auth_event, result: "failure")
      create(:auth_event, result: "success")
      expect(AuthEvent.failures.count).to eq(1)
    end

    it ".recent returns events within duration" do
      create(:auth_event, created_at: 5.minutes.ago)
      create(:auth_event, created_at: 20.minutes.ago)
      expect(AuthEvent.recent(10.minutes).count).to eq(1)
    end
  end
end
