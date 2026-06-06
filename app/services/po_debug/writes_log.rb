# frozen_string_literal: true

module PoDebug
  # Block 6 — Live PG/CH writes log for PO's current live stream.
  #
  # v0.1 Hot-Lite: STUB. v1.0 fills via ActiveSupport::Notifications subscriber
  # writing to a Redis LIST (LPUSH/LTRIM 20).
  class WritesLog
    def self.call
      new.call
    end

    def call
      {
        stub: true,
        message: "Coming in v1.0 (last 20 PG/CH writes with timing, filtered by stream_id)."
      }
    end
  end
end
