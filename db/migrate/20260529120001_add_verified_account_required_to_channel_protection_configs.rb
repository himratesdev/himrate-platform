# frozen_string_literal: true

# BUG-251.32: add `verified_account_required` boolean to channel_protection_configs.
# Replaces email_verification_required + phone_verification_required + minimum_account_age_minutes
# + restrict_first_time_chatters semantically — Twitch removed `Channel.accountVerificationOptions`
# subtype entirely (introspection 2026-05-29 confirms "Cannot query field 'accountVerificationOptions'").
# The new consolidated source is `chatSettings.requireVerifiedAccount` (boolean).
#
# Legacy columns are KEPT for backward read access on historical rows (do NOT drop in this PR —
# orthogonal cleanup tracked separately). New rows written by StreamMonitorWorker leave them NULL
# and populate the new `verified_account_required` column instead.

class AddVerifiedAccountRequiredToChannelProtectionConfigs < ActiveRecord::Migration[8.1]
  def change
    add_column :channel_protection_configs, :verified_account_required, :boolean, null: false, default: false
  end
end
