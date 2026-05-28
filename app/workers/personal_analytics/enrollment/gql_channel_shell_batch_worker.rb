# frozen_string_literal: true

# TASK-113 Δ-1 Wave 1 source #2 worker. Wraps GqlChannelShellBatchSource.call с Sidekiq retry.
# Queue :pva_gql_anon concurrency=10 (per ADR §6) — anonymous GQL has higher concurrency budget.
# Flag-gated :pva.
module PersonalAnalytics
  module Enrollment
    class GqlChannelShellBatchWorker
      include Sidekiq::Job
      sidekiq_options queue: :pva_gql_anon, retry: 2, dead: false

      def perform(user_id)
        return unless Flipper.enabled?(:pva)

        PersonalAnalytics::Enrollment::GqlChannelShellBatchSource.call(user_id)
      end
    end
  end
end
