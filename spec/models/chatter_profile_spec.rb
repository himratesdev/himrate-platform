# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatterProfile do
  it "validates login presence and uniqueness" do
    ChatterProfile.create!(login: "dupe", fetched_at: Time.current)
    dup = ChatterProfile.new(login: "dupe", fetched_at: Time.current)
    expect(dup).not_to be_valid
    expect(ChatterProfile.new(fetched_at: Time.current)).not_to be_valid
  end

  describe "#to_scorer_profile" do
    it "maps cached columns to the symbol-keyed hash Scorer#score_profile expects" do
      created = 5.days.ago
      broadcast = 2.days.ago
      cp = ChatterProfile.create!(
        login: "u1", twitch_user_id: "42", twitch_created_at: created,
        followers_count: 0, follows_count: 1500, profile_view_count: 0, videos_count: 0,
        description_present: true, banner_present: false, last_broadcast_at: broadcast,
        fetched_at: Time.current
      )

      p = cp.to_scorer_profile
      expect(p[:created_at]).to be_within(1.second).of(created)
      expect(p[:followers_count]).to eq(0)
      expect(p[:follows_count]).to eq(1500)
      expect(p[:profile_view_count]).to eq(0)
      expect(p[:videos_count]).to eq(0)
      expect(p[:description]).to eq("present")   # present? → non-nil sentinel
      expect(p[:banner_image_url]).to be_nil     # absent → nil (Scorer flags banner_null)
      expect(p[:last_broadcast_at]).to be_within(1.second).of(broadcast)
    end

    it "returns nil for description/banner when absent (so Scorer flags them)" do
      cp = ChatterProfile.create!(login: "u2", description_present: false, banner_present: false, fetched_at: Time.current)
      p = cp.to_scorer_profile
      expect(p[:description]).to be_nil
      expect(p[:banner_image_url]).to be_nil
    end
  end
end
