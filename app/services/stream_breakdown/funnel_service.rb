# frozen_string_literal: true

# T2-020 StreamBreakdown INC-1: chat funnel for the «Чат» tab — how the audience narrows from
# online → logged-in → writing-in-chat. High-water marks over the stream (peak of each), so the
# "huge online, tiny writing base" shape is visible. `norm_writing_per_1000` (the normal expected
# writers-per-1000-online baseline) is nil until the baseline calibration ships in INC-2 — we do NOT
# fabricate a norm.
module StreamBreakdown
  class FunnelService
    def initialize(stream:)
      @stream = stream
    end

    def call
      chatters = ChattersSnapshot.where(stream: @stream)
      {
        online: CcvSnapshot.where(stream: @stream).maximum(:ccv_count),
        logged_in: chatters.maximum(:chatters_present_total),
        writing: chatters.maximum(:unique_chatters_count),
        norm_writing_per_1000: nil # baseline → INC-2 (no fabrication)
      }
    end
  end
end
