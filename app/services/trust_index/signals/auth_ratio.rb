# frozen_string_literal: true

# TASK-028 FR-001: Auth Ratio signal.
# chatters.count / CCV, normalized by category threshold. Low auth ratio = view-only bots.
#
# TASK-251.6 — ABSTAINS server-side. This signal's expected_min≈0.65 calibration assumes
# "chatters PRESENT in chat" (≈ viewers connected to chat, historically ~0.5–1.0 of CCV).
# That count came from GQL chatters/CommunityTab, which is integrity-protected and NOT
# available server-side, and from the extension's browser-context ingest (gql_data), which
# is not yet wired. The only server-side chatter data is ACTIVE chat-senders (chat_messages,
# ~0.01–0.08 of CCV — measured on staging) — feeding that at 0.65 would yield value≈0.9 for
# EVERY channel = false view-bot flag (harmful + legal-sensitive). So we abstain rather than
# misfire. chatter_ccv_ratio (#2) already covers active-chatters/CCV at a calibrated threshold.
# Re-scope/recalibration (recalibrate-to-active / retire-as-redundant / wire present-chatters
# via extension gql_data) tracked in TASK-C1 (TI v2 signals) + TASK-251.9.

module TrustIndex
  module Signals
    class AuthRatio < BaseSignal
      def name = "Auth Ratio"
      def signal_type = "auth_ratio"

      def calculate(context)
        ccv = context[:latest_ccv]
        return insufficient(reason: "no_ccv") unless ccv&.positive?

        insufficient(reason: "chatters_present_unavailable_server_side")
      end
    end
  end
end
