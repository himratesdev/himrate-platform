# frozen_string_literal: true

# TASK-039 FR-006: GET /api/v1/channels/:id/trends/rehabilitation — M6 Rehabilitation Curve.
# Response per SRS §4.5 с bonus hash (integration с TrustIndex::RehabilitationTracker
# из TASK-039 A3b FR-046/047).
#
# Nothing to period-filter — rehabilitation event-based, не time-series. period param
# ignored для consistency API shape (base class валидация).

module Trends
  module Api
    class RehabilitationEndpointService < BaseEndpointService
      def call
        tracker_output = TrustIndex::RehabilitationTracker.call(channel)

        {
          data: tracker_output.merge(channel_id: channel.id, period: period),
          meta: meta
        }
      end
    end
  end
end
