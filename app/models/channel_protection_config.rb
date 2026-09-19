# frozen_string_literal: true

# TASK-025: Enhanced with validations.

class ChannelProtectionConfig < ApplicationRecord
  # DETECTION-AUDIT 2026-09-19 (CR iter-1 Nit-5): `channel_protection_score` never had a writer (0
  # non-null of 3 307 live rows) and its last reader is gone — CPS is scored from the settings
  # themselves (TrustIndex::Signals::ChannelProtectionScore.for_config). Step 1 of the rolling-safe
  # drop (the same pattern as Stream's peak_ccv guard): every AR connection running this code stops
  # SELECTing/INSERTing the column. The DROP ships in the NEXT deploy, not this one — load_defaults
  # 8.1 means partial_inserts=false, so a not-yet-replaced sidekiq container creating a first-ever
  # config mid-rollout would INSERT the dropped column, abort StreamMonitorWorker's tier-2 pass, and
  # its retry would re-run tier 1 (duplicate CCV/chatters snapshots — the detection pipeline's input).
  self.ignored_columns += %w[channel_protection_score]

  belongs_to :channel

  validates :channel_id, uniqueness: true
end
