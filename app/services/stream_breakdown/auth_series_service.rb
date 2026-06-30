# frozen_string_literal: true

# T2-020 StreamBreakdown INC-1: authenticated-login ratio over time for the «Вход в аккаунт» tab.
# ratio = chatters_present_total / ccv per snapshot (logged-in share of the online audience). Joins
# each ChattersSnapshot to the CcvSnapshot in the same minute. Snapshots without a present-count or
# without a positive ccv in that minute are skipped (no division-by-zero, no invented points).
module StreamBreakdown
  class AuthSeriesService
    def initialize(stream:)
      @stream = stream
    end

    def call
      present = ChattersSnapshot.where(stream: @stream)
                                .where.not(chatters_present_total: nil)
                                .order(timestamp: :asc)
      return [] if present.empty?

      ccv_by_minute = CcvSnapshot.where(stream: @stream)
                                 .order(timestamp: :asc)
                                 .index_by { |s| s.timestamp.change(sec: 0) }

      present.filter_map do |cs|
        ccv = ccv_by_minute[cs.timestamp.change(sec: 0)]&.ccv_count
        next unless ccv&.positive?

        { t: cs.timestamp.iso8601, ratio: (cs.chatters_present_total.to_f / ccv).round(4) }
      end
    end
  end
end
