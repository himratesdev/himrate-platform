# frozen_string_literal: true

# BUG-251.32: add `verified_account_required` boolean to channel_protection_configs.
# Replaces email_verification_required + phone_verification_required + minimum_account_age_minutes
# + restrict_first_time_chatters semantically — Twitch removed `Channel.accountVerificationOptions`
# subtype entirely (introspection 2026-05-29 confirms "Cannot query field 'accountVerificationOptions'").
# The new consolidated source is `chatSettings.requireVerifiedAccount` (boolean).
#
# Legacy columns are KEPT for backward read access on historical rows (do NOT drop in this PR —
# orthogonal cleanup tracked separately). They remain at their existing DB defaults
# (email_verification_required / phone_verification_required / restrict_first_time_chatters:
# null:false default:false; minimum_account_age_minutes: nullable) for new rows — no longer
# referenced by CPS scoring after BUG-251.32.
#
# Initialization semantics for `verified_account_required` on historical rows: default false
# means every pre-existing CPC row scores 0 for the 30-point component until the next Tier-2
# cycle (~5 min) overwrites them. Acceptable here because the root cause is exactly that those
# rows were stale/broken; the 5-min self-heal window matches existing Tier-2 cadence.

class AddVerifiedAccountRequiredToChannelProtectionConfigs < ActiveRecord::Migration[8.1]
  def change
    add_column :channel_protection_configs, :verified_account_required, :boolean, null: false, default: false
  end
end
