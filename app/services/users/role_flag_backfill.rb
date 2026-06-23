# frozen_string_literal: true

module Users
  # T1-060 FR-1 (phase-1) backfill: derive accumulating role flags from the current
  # mutually-exclusive scalars. Called by 20260623193000_add_role_flags_to_users and
  # re-callable from specs (test env loads structure.sql without data — same pattern as
  # CleanupRetentionConfigSeeder for TASK-086).
  #
  #   is_streamer ← role == 'streamer'            (faithful migration of current scalar)
  #   is_brand    ← tier == 'business'  OR  active membership in a business-tier team
  #
  # The is_brand team JOIN mirrors ApplicationPolicy#business_via_team? exactly (status
  # 'active', owner tier 'business'); the deleted_at non-filter is intentional parity with
  # that runtime predicate. Idempotent (plain UPDATE ... WHERE). Guarded on the legacy
  # `role` column so a from-scratch migrate stays safe after the phase-2 role-drop TASK.
  class RoleFlagBackfill
    def self.run!
      conn = ActiveRecord::Base.connection
      return unless conn.column_exists?(:users, :is_streamer)

      if conn.column_exists?(:users, :role)
        conn.execute("UPDATE users SET is_streamer = TRUE WHERE role = 'streamer'")
      end

      conn.execute("UPDATE users SET is_brand = TRUE WHERE tier = 'business'")
      conn.execute(<<~SQL.squish)
        UPDATE users u SET is_brand = TRUE
        FROM team_memberships tm
        JOIN users owners ON owners.id = tm.team_owner_id
        WHERE tm.user_id = u.id
          AND tm.status = 'active'
          AND owners.tier = 'business'
      SQL
    end
  end
end
