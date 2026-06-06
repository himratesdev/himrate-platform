# frozen_string_literal: true

module PoDebug
  # Block 3 — top-50 per-viewer breakdown for PO's current live stream.
  #
  # v0.1 Hot-Lite: STUB. v1.0 fills with PerUserBotScore join + watch_time
  # derivation via Trust::ViewerSessionPresences (PR #279).
  class ViewerBreakdown
    def self.call
      new.call
    end

    def call
      {
        stub: true,
        message: "Coming in v1.0 (top-50 viewers: login, sub badges, watch_time, bot_score, classification, last_chat_at)."
      }
    end
  end
end
