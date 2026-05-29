# frozen_string_literal: true

# BUG-251.33: recalibrate chatter_ccv_ratio (signal #2) expected_ratio_min thresholds.
#
# Root cause for false-positive alert on organic silent-audience streams:
#   The signal computes value = (expected_min - active_chatters/CCV) / expected_min when ratio
#   is below threshold (= viewbot suspicion). Existing thresholds were anchored on chat-active
#   typing rates that overestimate genuine engagement for video-game categories where viewers
#   watch without typing.
#
# Empirical baseline (live measurement 2026-05-29, justcooman organic Dota 2 partner):
#   - 22 active chatters last snapshot
#   - 1450 CCV
#   - ratio = 22/1450 = 0.0152 (1.5%)
#
# At the prior esports `expected_ratio_min = 0.02` (2%) → value = (0.02 - 0.0152)/0.02 = 0.24
# (low alert). Tolerable on its own but TI engine + chatter_ccv_ratio weight 0.10 contribute
# enough to push the system into "needs_review" classification for a genuinely clean channel.
#
# Recalibrated baselines (≈ 60-80% below empirical organic ratio per category) to give silent
# audiences ample headroom; viewbot-suspect threshold still meaningful when ratio drops near 0.
#
# Multi-channel validation tracked under EPIC BUG-251.28 Phase 4 (post-deploy, 10-channel survey).

class RecalibrateChatterCcvRatioForSilentAudienceCategories < ActiveRecord::Migration[8.1]
  RECALIBRATED = {
    "default"       => 0.040,  # was 0.100
    "esports"       => 0.005,  # was 0.020 — Dota/CS/LoL silent baseline 1-2%
    "just_chatting" => 0.150,  # was 0.200 — chat-heavy unchanged-ish
    "gaming"        => 0.040,  # was 0.100 — general gaming
    "irl"           => 0.080,  # was 0.125
    "music"         => 0.030   # was 0.067 — music streams quiet
  }.freeze

  LEGACY = {
    "default"       => 0.100,
    "esports"       => 0.020,
    "just_chatting" => 0.200,
    "gaming"        => 0.100,
    "irl"           => 0.125,
    "music"         => 0.067
  }.freeze

  def up
    RECALIBRATED.each do |category, value|
      rec = SignalConfiguration.find_or_initialize_by(
        signal_type: "chatter_ccv_ratio", category: category, param_name: "expected_ratio_min"
      )
      rec.param_value = value
      rec.save!
    end
  end

  def down
    LEGACY.each do |category, value|
      rec = SignalConfiguration.find_by(
        signal_type: "chatter_ccv_ratio", category: category, param_name: "expected_ratio_min"
      )
      rec&.update!(param_value: value)
    end
  end
end
