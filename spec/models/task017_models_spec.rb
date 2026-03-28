# frozen_string_literal: true

require "rails_helper"

RSpec.describe "TASK-017 Models", type: :model do
  describe StreamerRating do
    it { is_expected.to belong_to(:channel) }
    it { is_expected.to validate_presence_of(:rating_score) }
    it { is_expected.to validate_presence_of(:calculated_at) }

    it "validates rating_score range 0-100" do
      rating = build(:streamer_rating, rating_score: 101)
      expect(rating).not_to be_valid
    end

    it "validates decay_lambda range 0-1" do
      expect(build(:streamer_rating, decay_lambda: 0)).not_to be_valid
      expect(build(:streamer_rating, decay_lambda: -0.1)).not_to be_valid
      expect(build(:streamer_rating, decay_lambda: 1.1)).not_to be_valid
      expect(build(:streamer_rating, decay_lambda: 0.05)).to be_valid
      expect(build(:streamer_rating, decay_lambda: 1.0)).to be_valid
    end

    it "creates valid record via factory" do
      rating = create(:streamer_rating)
      expect(rating).to be_persisted
    end
  end

  describe FollowerSnapshot do
    it { is_expected.to belong_to(:channel) }
    it { is_expected.to validate_presence_of(:timestamp) }
    it { is_expected.to validate_presence_of(:followers_count) }

    it "creates valid record via factory" do
      snapshot = create(:follower_snapshot)
      expect(snapshot).to be_persisted
    end
  end

  describe CrossChannelPresence do
    it { is_expected.to belong_to(:channel) }
    it { is_expected.to belong_to(:stream).optional }
    it { is_expected.to validate_presence_of(:username) }
    it { is_expected.to validate_presence_of(:first_seen_at) }

    it "creates valid record via factory" do
      presence = create(:cross_channel_presence)
      expect(presence).to be_persisted
    end
  end

  describe BillingEvent do
    it { is_expected.to belong_to(:user) }
    it { is_expected.to validate_presence_of(:event_type) }
    it { is_expected.to validate_presence_of(:provider_event_id) }
    it { is_expected.to validate_presence_of(:provider) }

    it "validates event_type inclusion" do
      event = build(:billing_event, event_type: "invalid")
      expect(event).not_to be_valid
    end

    it "validates provider inclusion" do
      event = build(:billing_event, provider: "invalid")
      expect(event).not_to be_valid
    end

    it "allows valid providers" do
      BillingEvent::PROVIDERS.each do |p|
        event = build(:billing_event, provider: p)
        expect(event).to be_valid, "Expected '#{p}' to be valid"
      end
    end

    it "allows valid event_types" do
      BillingEvent::EVENT_TYPES.each do |type|
        event = build(:billing_event, event_type: type)
        expect(event).to be_valid, "Expected '#{type}' to be valid"
      end
    end

    it "enforces provider_event_id uniqueness" do
      create(:billing_event, provider_event_id: "evt_dup")
      dup = build(:billing_event, provider_event_id: "evt_dup")
      expect(dup).not_to be_valid
    end
  end

  describe PredictionsPoll do
    it { is_expected.to belong_to(:stream) }
    it { is_expected.to validate_presence_of(:event_type) }
    it { is_expected.to validate_presence_of(:participants_count) }

    it "validates event_type inclusion" do
      poll = build(:predictions_poll, event_type: "invalid")
      expect(poll).not_to be_valid
    end

    it "allows prediction and poll" do
      %w[prediction poll].each do |type|
        poll = build(:predictions_poll, event_type: type)
        expect(poll).to be_valid
      end
    end
  end
end
