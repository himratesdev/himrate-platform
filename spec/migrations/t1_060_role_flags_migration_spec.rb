# frozen_string_literal: true

require "rails_helper"

# T1-060 FR-1 (phase-1) migration verification: the stored is_streamer column, its partial
# index, and the Users::RoleFlagBackfill derivation from the legacy role scalar. Test env
# loads structure.sql without data, so the backfill is re-invoked against seeded rows (same
# approach as the TASK-086 migration spec / CleanupRetentionConfigSeeder). Rows are created
# with is_streamer explicitly false so the factory's derive default cannot mask whether the
# backfill itself sets it. (brand is derived at read-time — there is no is_brand column.)
RSpec.describe "T1-060 role flags migration", type: :model do
  let(:conn) { ActiveRecord::Base.connection }

  describe "schema" do
    it "adds the is_streamer boolean column, NOT NULL default false" do
      column = conn.columns(:users).find { |c| c.name == "is_streamer" }
      expect(column).to be_present
      expect(column.type).to eq(:boolean)
      expect(column.null).to be false
      expect(column.default).to eq(false) # PG boolean default is cast to a real boolean
    end

    it "adds a partial index on is_streamer WHERE is_streamer = true" do
      idx = conn.indexes(:users).find { |i| i.columns == [ "is_streamer" ] }
      expect(idx).to be_present
      expect(idx.where).to include("is_streamer = true")
    end

    it "does NOT add an is_brand column (brand derives at read-time)" do
      expect(conn.columns(:users).map(&:name)).not_to include("is_brand")
    end
  end

  describe "Users::RoleFlagBackfill.run!" do
    it "sets is_streamer = true for role = 'streamer'" do
      streamer = create(:user, role: "streamer", is_streamer: false)
      viewer = create(:user, role: "viewer", is_streamer: false)

      Users::RoleFlagBackfill.run!

      expect(streamer.reload.is_streamer).to be true
      expect(viewer.reload.is_streamer).to be false
    end

    it "is idempotent" do
      streamer = create(:user, role: "streamer", is_streamer: false)

      2.times { Users::RoleFlagBackfill.run! }

      expect(streamer.reload.is_streamer).to be true
    end
  end
end
