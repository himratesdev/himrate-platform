# frozen_string_literal: true

require "rails_helper"

# T1-060 FR-1 (phase-1) migration verification: columns, partial indexes, and the
# Users::RoleFlagBackfill derivation. Test env loads structure.sql without data, so the
# backfill is re-invoked against seeded rows (same approach as the TASK-086 migration spec
# / CleanupRetentionConfigSeeder). Backfill rows are created with the flags explicitly set
# false so the factory's derive default cannot mask whether the backfill itself sets them.
RSpec.describe "T1-060 role flags migration", type: :model do
  let(:conn) { ActiveRecord::Base.connection }

  describe "schema" do
    it "adds is_streamer and is_brand boolean columns, NOT NULL default false" do
      %i[is_streamer is_brand].each do |col|
        column = conn.columns(:users).find { |c| c.name == col.to_s }
        expect(column).to be_present, "expected users.#{col} to exist"
        expect(column.type).to eq(:boolean)
        expect(column.null).to be false
        expect(column.default).to eq(false) # PG boolean default is cast to a real boolean
      end
    end

    it "adds a partial index on is_streamer WHERE is_streamer = true" do
      idx = conn.indexes(:users).find { |i| i.columns == [ "is_streamer" ] }
      expect(idx).to be_present
      expect(idx.where).to include("is_streamer = true")
    end

    it "adds a partial index on is_brand WHERE is_brand = true" do
      idx = conn.indexes(:users).find { |i| i.columns == [ "is_brand" ] }
      expect(idx).to be_present
      expect(idx.where).to include("is_brand = true")
    end
  end

  describe "Users::RoleFlagBackfill.run!" do
    it "sets is_streamer = true for role = 'streamer'" do
      u = create(:user, role: "streamer", is_streamer: false)
      viewer = create(:user, role: "viewer", is_streamer: false)

      Users::RoleFlagBackfill.run!

      expect(u.reload.is_streamer).to be true
      expect(viewer.reload.is_streamer).to be false
    end

    it "sets is_brand = true for tier = 'business'" do
      biz = create(:user, tier: "business", is_brand: false)
      free = create(:user, tier: "free", is_brand: false)

      Users::RoleFlagBackfill.run!

      expect(biz.reload.is_brand).to be true
      expect(free.reload.is_brand).to be false
    end

    it "sets is_brand = true for an active member of a business-tier team (bridge)" do
      owner = create(:user, tier: "business")
      member = create(:user, tier: "free", is_brand: false)
      create(:team_membership, user: member, team_owner: owner, status: "active")

      Users::RoleFlagBackfill.run!

      expect(member.reload.is_brand).to be true
    end

    it "does NOT bridge is_brand for a removed team membership" do
      owner = create(:user, tier: "business")
      member = create(:user, tier: "free", is_brand: false)
      create(:team_membership, user: member, team_owner: owner, status: "removed")

      Users::RoleFlagBackfill.run!

      expect(member.reload.is_brand).to be false
    end

    it "is idempotent" do
      u = create(:user, role: "streamer", tier: "business", is_streamer: false, is_brand: false)

      2.times { Users::RoleFlagBackfill.run! }

      expect(u.reload.is_streamer).to be true
      expect(u.is_brand).to be true
    end
  end
end
