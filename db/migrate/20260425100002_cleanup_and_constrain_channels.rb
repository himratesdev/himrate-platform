# frozen_string_literal: true

# BUG-012: Cleanup legacy violations + enforce tracked_channels.subscription_id
# NOT NULL. UNIQUE index on channels.login extracted в separate migration
# 20260425100003 (CONCURRENTLY requires disable_ddl_transaction!).
#
# Cleanup scope:
#   - 4 orphan TrackedChannel rows с NULL subscription_id (legacy artefacts)
#   - N duplicate Channel records с одинаковым login (race condition в
#     ChannelSeeder.find_or_create_by! pre-fix)
#
# CR N-3: cleanup logic inlined (no application code coupling). Migration
# self-contained — survives ChannelSeeder rename/refactor in future.

class CleanupAndConstrainChannels < ActiveRecord::Migration[8.0]
  def up
    cleanup_orphan_tracked_channels
    dedupe_duplicate_channels
    enforce_subscription_id_not_null
  end

  def down
    change_column_null :tracked_channels, :subscription_id, true
    # Data deletions (orphan TCs + duplicate channels + their dependents) not reversible.
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
        delete_channel_chain(loser)
      end
      say "Kept canonical Channel #{keeper.id} for login=#{login} (created_at=#{keeper.created_at})"
    end
  end

  # CR N-3: inline cleanup chain — duplicates production teardown_channel order
  # but без зависимости на VQA seeder namespace. FK references reverse-deleted
  # перед Channel.destroy! triggers AR-declared dependents.
  def delete_channel_chain(channel)
    AnomalyAttribution
      .joins(anomaly: :stream)
      .where(streams: { channel_id: channel.id })
      .delete_all
    Anomaly.joins(:stream).where(streams: { channel_id: channel.id }).delete_all
    TrustIndexHistory.where(channel_id: channel.id).delete_all
    TrendsDailyAggregate.where(channel_id: channel.id).delete_all
    HsTierChangeEvent.where(channel_id: channel.id).delete_all if defined?(HsTierChangeEvent)
    RehabilitationPenaltyEvent.where(channel_id: channel.id).delete_all if defined?(RehabilitationPenaltyEvent)
    FollowerSnapshot.where(channel_id: channel.id).delete_all
    channel.streams.delete_all
    TrackedChannel.where(channel_id: channel.id).delete_all
    channel.destroy!
  end

  def enforce_subscription_id_not_null
    change_column_null :tracked_channels, :subscription_id, false
    say "Enforced NOT NULL on tracked_channels.subscription_id"
  end
end
