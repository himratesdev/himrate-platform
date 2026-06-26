# frozen_string_literal: true

module BotDetection
  # T1-057 (BR-10): allowlist of KNOWN PLATFORM utility bots (moderation / polls / alerts).
  #
  # These accounts are present in many channels by design (a streamer installs nightbot to moderate
  # chat) and naturally trip the cross-channel temporal co-occurrence signal with very high R. They
  # are NOT audience fraud — penalising a channel's Trust Index for running a mod bot would be a
  # false positive on the product's core job. So the CrossChannelIntelligenceWorker classifies any
  # match here as bot_type=utility and the TI signal (TemporalCrossChannel) excludes utility from
  # the fraud value (still recorded with its tier for observability).
  #
  # Why an exact-match frozen Set (not a pattern / wildcard):
  #   - Twitch usernames are unique, so an impersonator "nightbot_2" is a DIFFERENT account and is
  #     NOT allowlisted — it gets classified by its own R/mc like any bot (exact-match is the TIGHT,
  #     evasion-safe choice; a wildcard would let a spam bot hide under a near-name).
  #   - The allowlist EXCLUDES from penalty, so breadth is the risk, not precision. Keep it curated.
  # Residual (accepted): a brand-new utility bot not yet in this list is spam-flagged until added —
  # maintained via PR (build-for-scale: code-reviewed change, not a runtime admin toggle).
  #
  # Source: Probe-2 calibration (run 28142215588 top offenders) + the well-known Twitch bot roster.
  module KnownPlatformBots
    LIST = %w[
      nightbot
      streamelements
      streamlabs
      moobot
      fossabot
      wizebot
      rupoll
      sery_bot
      pretzelrocks
      soundalerts
      commanderroot
      streamlootsbot
      tangiabot
      botrixoficial
      kofistreambot
    ].to_set.freeze

    module_function

    # Usernames arrive IRC-lowercase from ClickHouse chat_messages; downcase defensively so the
    # allowlist is case-insensitive regardless of caller.
    def utility?(username)
      return false if username.nil?

      LIST.include?(username.to_s.downcase)
    end
  end
end
