# frozen_string_literal: true

# TASK-113 Δ-1 Wave 1 (FR-016 OQ-8): sweep cron, 5-min cadence. Marks stuck enrollment states
# (oauth_linked_at > 10 min ago, overall_status pending|in_progress|partial) as `partial_timeout`.
# Completed-earlier sources retain their `done` state + persisted data; failed/timed-out sources
# show retry CTA in UI per §11.6.
module PersonalAnalytics
  module Enrollment
    class EnrollmentBackfillSweepWorker
      include Sidekiq::Job
      # CR iter-3 N1: align queue with cron schedule (:monitoring) — was :default.
      sidekiq_options queue: :monitoring, retry: 1

      def perform
        return unless Flipper.enabled?(:pva)

        PvaEnrollmentBackfillState.stuck(10.minutes.ago).find_each do |state|
          PersonalAnalytics::Enrollment::StateStore.mark_partial_timeout(state)
        end
      end
    end
  end
end
