# frozen_string_literal: true

# BUG-012: Enforce DB-level invariants для channels.login uniqueness и
# tracked_channels.subscription_id NOT NULL. Cleanup legacy violations:
#   - 4 orphan TrackedChannel rows с NULL subscription_id (legacy artefacts)
#   - N duplicate Channel records с одинаковым login (race condition в
#     ChannelSeeder.find_or_create_by! pre-fix)
#
# Build-for-years: implicit application invariants (ChannelPolicy expects
# subscription_id, ChannelSeeder expects login uniqueness) hoisted к DB-level
# constraints. Race conditions становятся physically impossible.
#
# Safety guard: refuses dedupe non-VQA duplicates (real channels) — manual review.

class CleanupAndConstrainChannels < ActiveRecord::Migration[8.0]
  def up
    cleanup_orphan_tracked_channels
    dedupe_duplicate_channels
    enforce_subscription_id_not_null
    enforce_channels_login_unique
  end

  def down
    remove_index :channels, :login, if_exists: true
    change_column_null :tracked_channels, :subscription_id, true
    # Data deletions (orphan TCs + duplicate channels) are not reversible.
  end

  private

  def cleanup_orphan_tracked_channels
    deleted = ActiveRecord::Base.connection.execute(
      "DELETE FROM tracked_channels WHERE subscription_id IS NULL"
    ).cmd_tuples
    say "Deleted #{deleted} orphan TrackedChannel rows (NULL subscription_id)"
  end

  def dedupe_duplicate_channels
    duplicate_logins = Channel.group(:login).having("COUNT(*) > 1").pluck(:login)
    return say("No duplicate channel logins — skip dedupe") if duplicate_logins.empty?

    duplicate_logins.each do |login|
      records = Channel.where(login: login).order(:created_at)
      keeper = records.first
      losers = records.offset(1).to_a

      # Safety: only auto-cleanup VQA-prefixed channels. Production-class
      # duplicate logins (real Twitch channels) require operator review.
      unless login.start_with?("vqa_test_")
        raise <<~MSG
          Non-VQA duplicate Channel login detected: '#{login}' (#{records.size} records).
          Manual review required — refusing to auto-dedupe production data.
          Channel IDs: #{records.pluck(:id).join(', ')}
        MSG
      end

      losers.each do |loser|
        say "Tearing down duplicate Channel #{loser.id} (login=#{login}, created_at=#{loser.created_at})"
        Trends::VisualQa::ChannelSeeder.teardown_channel(channel: loser)
      end
      say "Kept canonical Channel #{keeper.id} for login=#{login} (created_at=#{keeper.created_at})"
    end
  end

  def enforce_subscription_id_not_null
    change_column_null :tracked_channels, :subscription_id, false
    say "Enforced NOT NULL on tracked_channels.subscription_id"
  end

  def enforce_channels_login_unique
    add_index :channels, :login, unique: true, if_not_exists: true,
      name: "index_channels_on_login_unique"
    say "Added UNIQUE index on channels.login"
  end
end
