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
    it "maps cached columns to the symbol-keyed hash Scorer#score_profile reads (bot-trait fields only)" do
      created = 5.days.ago
      cp = ChatterProfile.create!(
        login: "u1", twitch_user_id: "42", twitch_created_at: created,
        followers_count: 0, follows_count: 1500, profile_view_count: 0, fetched_at: Time.current
      )

      p = cp.to_scorer_profile
      expect(p[:created_at]).to be_within(1.second).of(created)
      expect(p[:followers_count]).to eq(0)
      expect(p[:follows_count]).to eq(1500)
      expect(p[:profile_view_count]).to eq(0)
      # Streamer-presence fields are no longer scored, so they are not stored/returned.
      expect(p).not_to have_key(:description)
      expect(p).not_to have_key(:banner_image_url)
    end
  end
end
