# frozen_string_literal: true

# TASK-113 Δ-1 Wave 1 (FR-016): parent orchestrator worker. Triggered from Twitch OAuth callback
# success handler. Initiates state row + enqueues child source workers in parallel (BR-013 isolated
# failure semantics — sources не блокируют друг друга).
#
# Wave 1 children:
#   - HelixFollowsBackfillWorker (source #1)
#   - GqlChannelShellBatchWorker (source #2)
#   - Source #5 Apollo cache walk = extension-side (POST to /api/v1/me/analytics/cold_start/subs_payload)
#
# Deferred:
#   - Source #3 ClickhouseChatMessagesBackfillWorker → Wave 2 после T1 cutover
#   - Source #4 GqlSelfSubsReplay → optional optimization после PO DevTools spike
#
# Idempotency (BR-015): skip if `last_backfilled_at < 30d`, unless force=true.
# Flag-gated :pva.
module PersonalAnalytics
  module Enrollment
    class EnrollmentBackfillWorker
      include Sidekiq::Job
      sidekiq_options queue: :pva_critical, retry: 3, dead: false

      # CR iter-3 N3: positional arg (Sidekiq does not reliably round-trip kwargs через
      # perform_async → JSON → worker). Default false для Twitch callback hook.
      def perform(user_id, force = false)
        return unless Flipper.enabled?(:pva)

        state, status = PersonalAnalytics::Enrollment::StateStore.initiate(user_id: user_id, force: force)
        return if status == :reused

        # Spawn child workers parallel (independent queues, isolated failure).
        HelixFollowsBackfillWorker.perform_async(user_id)
        GqlChannelShellBatchWorker.perform_async(user_id)
        # Source #5 fires from extension after first PVA tab open — not enqueued here.

        state
      end
    end
  end
end
