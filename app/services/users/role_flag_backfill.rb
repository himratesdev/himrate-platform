# frozen_string_literal: true

module Users
  # T1-060 FR-1 (phase-1) backfill: seed the stored is_streamer flag from the legacy role
  # scalar (faithful migration of current reality). Called by
  # 20260623193000_add_role_flags_to_users and re-callable from specs (test env loads
  # structure.sql without data — same pattern as CleanupRetentionConfigSeeder for TASK-086).
  #
  # There is no is_brand backfill: brand status is derived at read-time from business access
  # (User#brand?), so there is no stored column to seed. Idempotent (plain UPDATE ... WHERE);
  # guarded on the legacy `role` column so a from-scratch migrate stays safe after phase-2.
  class RoleFlagBackfill
    def self.run!
      conn = ActiveRecord::Base.connection
      return unless conn.column_exists?(:users, :is_streamer)
      return unless conn.column_exists?(:users, :role)

      conn.execute("UPDATE users SET is_streamer = TRUE WHERE role = 'streamer'")
    end
  end
end
