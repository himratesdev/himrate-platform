# frozen_string_literal: true

module PoDebug
  # Block 7 — Errors/warnings tagged with PO's current live stream.
  #
  # v0.1 Hot-Lite: STUB. v1.0 fills via logger.tagged(:po_debug) warnings
  # stored in Redis LIST.
  class ErrorsLog
    def self.call
      new.call
    end

    def call
      {
        stub: true,
        message: "Coming in v1.0 (last 20 logger.tagged(:po_debug) warnings per current stream_id)."
      }
    end
  end
end
