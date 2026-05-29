# frozen_string_literal: true

# BUG-251.30: recalibrate auth_ratio SignalConfiguration expected_min for the actual
# CommunityTab presence semantics.
#
# Background: original seeds (db/seeds.rb) set expected_min to 0.58–0.75 across categories,
# anchored on the assumption that "chatters present" would map to Twitch's chat widget
# presence count (~50–100% of CCV historically). The CommunityTab GQL operation returns a
# narrower subset: broadcasters + moderators + vips + staff + viewers arrays representing
# registered users with an active chat tab in the last few minutes. Twitch additionally caps
# `viewers` at 100 per response.
#
# Empirical baseline (live measurement 2026-05-29 — justcooman, Dota 2 partner, 154 min live):
#   - 106 registered chatters (broadcasters 1 + moderators 3 + vips 2 + staff 0 + viewers 100)
#   - 1450 total CCV
#   - ratio = 106 / 1450 = 0.073 (7.3%)
#
# At the legacy 0.58 esports threshold this would compute value = (0.58 - 0.073) / 0.58 = 0.87
# = strong viewbot alert on a genuine organic Dota partner. False-positive across the entire
# silent-audience category set.
#
# Conservative recalibration (this migration): floor thresholds well below the empirically-
# observed ratio so genuine streams pass, while still flagging extreme view-bot inflation
# (ratio < 1% under default-category threshold).
#
# Multi-channel empirical recalibration tracked under BUG-251.33 (TI per-category recalibration).
#
# Reversibility: `down` restores the pre-BUG-251.30 seeded values.

class RecalibrateAuthRatioExpectedMinForChattersPresence < ActiveRecord::Migration[8.1]
  RECALIBRATED = {
    "default"       => 0.030,
    "esports"       => 0.010,
    "just_chatting" => 0.050,
    "gaming"        => 0.025,
    "irl"           => 0.040,
    "music"         => 0.020
  }.freeze

  LEGACY = {
    "default"       => 0.65,
    "esports"       => 0.58,
    "just_chatting" => 0.75,
    "gaming"        => 0.65,
    "irl"           => 0.70,
    "music"         => 0.60
  }.freeze

  def up
    RECALIBRATED.each do |category, value|
      rec = SignalConfiguration.find_or_initialize_by(
        signal_type: "auth_ratio", category: category, param_name: "expected_min"
      )
      rec.param_value = value
      rec.save!
    end
  end

  def down
    LEGACY.each do |category, value|
      rec = SignalConfiguration.find_by(
        signal_type: "auth_ratio", category: category, param_name: "expected_min"
      )
      rec&.update!(param_value: value)
    end
  end
end
