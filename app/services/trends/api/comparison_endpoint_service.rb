# frozen_string_literal: true

# TASK-039 FR-007: GET /api/v1/channels/:id/trends/comparison — M11 Peer Comparison.
# Response per SRS §4 peer comparison shape (объединяет Stability peer + category scope).
#
# Policy (FR-014): view_peer_comparison? (Premium / Business / Streamer OAuth).
# Min category channels gate (SignalConfig trends/peer_comparison/min_category_channels, 100)
# → insufficient_category_data если меньше (SRS US-009).
#
# Category param: обязательный для multi-category channels. Если не передан — используется
# latest stream category. Переопределение через ?category= для explicit scope.

module Trends
  module Api
    class ComparisonEndpointService < BaseEndpointService
      def initialize(channel:, period:, granularity: nil, category: nil, user: nil)
        super(channel: channel, period: period, granularity: granularity, user: user)
        @category = category.presence || resolve_default_category
      end

      def call
        from_ts, to_ts = range

        if @category.nil?
          return {
            data: {
              channel_id: channel.id,
              period: period,
              from: from_ts.iso8601,
              to: to_ts.iso8601,
              category: nil,
              insufficient_data: true,
              reason: "no_category_history"
            },
            meta: meta
          }
        end

        peer = Trends::Analysis::PeerComparisonService.call(
          channel: channel, category: @category, period: period
        )

        {
          data: {
            channel_id: channel.id,
            period: period,
            from: from_ts.iso8601,
            to: to_ts.iso8601,
            **peer
          },
          meta: meta
        }
      end

      private

      def resolve_default_category
        channel.streams.where.not(game_name: nil).order(started_at: :desc).pick(:game_name)
      end
    end
  end
end
