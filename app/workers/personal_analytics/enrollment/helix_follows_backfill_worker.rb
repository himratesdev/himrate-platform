# frozen_string_literal: true

# TASK-113 Δ-1 Wave 1 source #1 worker. Wraps HelixFollowsSource.call с Sidekiq retry semantics.
# Queue :pva_helix concurrency=5 (per ADR §6) — bounded для Helix rate-limit pool (800 req/min).
# Flag-gated :pva (kill-switch).
module PersonalAnalytics
  module Enrollment
    class HelixFollowsBackfillWorker
      include Sidekiq::Job
      sidekiq_options queue: :pva_helix, retry: 3, dead: false

      def perform(user_id)
        return unless Flipper.enabled?(:pva)

        PersonalAnalytics::Enrollment::HelixFollowsSource.call(user_id)
      end
    end
  end
end
