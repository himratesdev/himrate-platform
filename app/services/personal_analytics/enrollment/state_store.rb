# frozen_string_literal: true

# TASK-113 Δ-1 Wave 1 (FR-016): mediator между Postgres `pva_enrollment_backfill_state` (durable)
# и Redis `pva:backfill:{user_id}` hash (fast read для frontend polling, TTL 24h).
#
# Single API: создание state row на enrollment, обновление per-source state, queries для frontend.
# Атомарность achieved через transaction (rows are independent per user; no cross-user state).
# Per ADR v3.0 Variant B: 5 workers (3 backend + extension-handler для #5) пишут в этот mediator
# параллельно через update_source_state(). Per-source isolated failure (BR-013) — каждый источник
# пишет свою cell в Redis hash + sources jsonb без cross-source coordination.
module PersonalAnalytics
  module Enrollment
    class StateStore
      SOURCE_KEYS = PvaEnrollmentBackfillState::SOURCE_KEYS
      REDIS_TTL = 86_400 # 24 hours
      OVERALL_STUCK_THRESHOLD = 10.minutes

      class << self
        # Создаёт state row + Redis hash для нового enrollment. Idempotent — re-trigger возвращает
        # existing row если recent_completion? (BR-015 skip-logic <30d), unless force=true.
        # Returns [state_row, :created | :reused].
        def initiate(user_id:, force: false)
          existing = PvaEnrollmentBackfillState.find_by(user_id: user_id)
          if existing && existing.recent_completion? && !force
            return [ existing, :reused ]
          end

          state = existing || PvaEnrollmentBackfillState.new(user_id: user_id)
          state.assign_attributes(
            oauth_linked_at: Time.current,
            overall_status: "pending",
            sources: initial_sources_payload,
            completed_at: nil,
            failed_sources: []
          )
          state.save!

          write_redis_hash(user_id, state.sources)
          [ state, :created ]
        end

        # Per-source state update. Worker calls when starting / completing / failing a source.
        # source_key = "source_1".."source_5" (per ADR §4 mapping).
        # payload = { status:, started_at:, completed_at:, rows_affected:, error_class: }
        def update_source(user_id:, source_key:, payload:)
          raise ArgumentError, "invalid source_key #{source_key.inspect}" unless SOURCE_KEYS.include?(source_key)

          state = PvaEnrollmentBackfillState.find_by(user_id: user_id)
          return nil unless state

          ActiveRecord::Base.transaction do
            state.lock!
            new_sources = (state.sources || {}).deep_dup
            new_sources[source_key] = (new_sources[source_key] || {}).merge(payload.stringify_keys)
            state.sources = new_sources

            state.failed_sources = new_sources.select { |_, v| v["status"] == "failed" }.keys.sort

            overall = compute_overall_status(new_sources)
            state.overall_status = overall
            state.completed_at = Time.current if terminal_status?(overall) && state.completed_at.nil?
            state.save!
          end

          write_redis_hash(user_id, state.sources)
          state
        end

        # Reset a single source cell back to pending state — used by ColdStartController#retry_source
        # для banner per-source retry CTA (FR-016 §11.6). Re-enqueueing the corresponding worker
        # happens в caller (controller) — StateStore only handles the state mutation.
        # Returns the updated state row, or nil если no enrollment row exists.
        def reset_source(user_id:, source_key:)
          raise ArgumentError, "invalid source_key #{source_key.inspect}" unless SOURCE_KEYS.include?(source_key)

          state = PvaEnrollmentBackfillState.find_by(user_id: user_id)
          return nil unless state

          ActiveRecord::Base.transaction do
            state.lock!
            new_sources = (state.sources || {}).deep_dup
            new_sources[source_key] = {
              "status" => "pending", "started_at" => nil, "completed_at" => nil,
              "rows_affected" => 0, "error_class" => nil
            }
            state.sources = new_sources
            state.failed_sources = new_sources.select { |_, v| v["status"] == "failed" }.keys.sort
            state.overall_status = compute_overall_status(new_sources)
            # Clear completed_at чтобы recent_completion? skip-logic не triggered после retry —
            # frontend orchestrator must observe non-terminal state и resume polling.
            state.completed_at = nil if state.overall_status != "done"
            state.save!
          end

          write_redis_hash(user_id, state.sources)
          state
        end

        # Mark stuck enrollments как partial_timeout. Run from sweep cron (5-min cadence).
        def mark_partial_timeout(state)
          ActiveRecord::Base.transaction do
            state.lock!
            new_sources = (state.sources || {}).deep_dup
            new_sources.each do |key, source|
              next unless %w[pending in_progress].include?(source["status"])
              source["status"] = "failed"
              source["error_class"] = "EnrollmentTimeout"
              source["completed_at"] = Time.current.iso8601
            end
            state.sources = new_sources
            state.failed_sources = new_sources.select { |_, v| v["status"] == "failed" }.keys.sort
            state.overall_status = "partial_timeout"
            state.completed_at = Time.current if state.completed_at.nil?
            state.save!
          end
          write_redis_hash(state.user_id, state.sources)
          state
        end

        # CR iter-2 N2: simplified to PG-only read after baseline measurement.
        # Previous "Redis-first" branch still called read_metadata_from_pg unconditionally
        # → 1 HGETALL + 1 SELECT (worse than just PG). Polling cadence 5s × N users — PG
        # SELECT по unique user_id index <1ms; не warranting Redis-cache complexity для Wave 1.
        # Wave 2 enhancement: persist overall_status/completed_at/failed_sources в Redis hash
        # с update_source write для true Redis-first read.
        def read_state(user_id:)
          state = PvaEnrollmentBackfillState.find_by(user_id: user_id)
          return nil unless state

          (state.sources || {}).merge(
            "overall_status" => state.overall_status,
            "completed_at" => state.completed_at&.iso8601,
            "oauth_linked_at" => state.oauth_linked_at.iso8601,
            "failed_sources" => state.failed_sources
          )
        end

        private

        def initial_sources_payload
          SOURCE_KEYS.each_with_object({}) do |key, h|
            h[key] = { "status" => "pending", "started_at" => nil, "completed_at" => nil,
                       "rows_affected" => 0, "error_class" => nil }
          end
        end

        # CR iter-4 N3: "partial" wins over "pending" в mixed scenarios.
        # Если есть done + failed но ещё pending source_5 (extension-driven, может прийти позже),
        # mark partial + completed_at сразу — sweep marks late stuck sources через mark_partial_timeout
        # после 10-min threshold (BR-013 isolated failure + UI retry CTA path).
        def compute_overall_status(sources)
          statuses = sources.values.map { |s| s["status"] }
          return "failed" if statuses.all? { |s| s == "failed" }
          return "done" if statuses.all? { |s| s == "done" }
          return "partial" if statuses.any? { |s| s == "done" } && statuses.any? { |s| s == "failed" }
          return "in_progress" if statuses.any? { |s| s == "in_progress" }
          return "in_progress" if statuses.any? { |s| s == "done" } || statuses.any? { |s| s == "failed" }
          "pending"
        end

        def terminal_status?(status)
          %w[done failed partial partial_timeout].include?(status)
        end

        def redis_key(user_id)
          "pva:backfill:#{user_id}"
        end

        # CR iter-1 M1: use block form per-call. ConnectionPool#with checks out a connection,
        # yields, returns to pool on exit. Caching @redis = connection-leak + cross-thread
        # corruption (StateStore singleton, Sidekiq + Puma threads share). Block-per-call ensures
        # each operation gets a freshly checked-out connection, returned cleanly.
        # Used by update_source/initiate/mark_partial_timeout — write-only path для Wave 1.
        # (read_redis_hash removed CR iter-3 N2 после CR iter-2 N2 PG-only simplification.)
        def write_redis_hash(user_id, sources)
          return unless defined?(Sidekiq)
          payload = sources.transform_values(&:to_json)
          Sidekiq.redis_pool.with do |conn|
            conn.mapped_hmset(redis_key(user_id), payload)
            conn.expire(redis_key(user_id), REDIS_TTL)
          end
        rescue StandardError => e
          Rails.logger.warn("[PVA EnrollmentBackfill] Redis write failed: #{e.class} #{e.message}")
        end
      end
    end
  end
end
