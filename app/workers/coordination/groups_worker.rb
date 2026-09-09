# frozen_string_literal: true

module Coordination
  # Assembles the persisted ring snapshot from the collected hours (Coordination::Snapshot).
  # Separate from the collector on purpose: collection must run every hour to keep the window
  # complete, assembly only has to be fresh enough for a page load, and a failure in one must not
  # take down the other.
  class GroupsWorker
    include Sidekiq::Job
    sidekiq_options queue: :long_running, retry: 1

    FLAG = :coordination_engine

    LOCK_KEY = "coordination:groups:lock"
    LOCK_TTL = 20.minutes.to_i

    def perform
      return unless Flipper.enabled?(FLAG)
      # Release only what we took: an early return on a held lock must not free the run that owns it.
      return unless acquire_lock

      begin
        stats = Coordination::Snapshot.call
        Rails.logger.info(
          "Coordination::GroupsWorker groups=#{stats[:groups]} members=#{stats[:members]} " \
          "accounts=#{stats[:accounts]} corroborated=#{stats[:corroborated]}"
        )
      rescue Clickhouse::Error => e
        Rails.logger.error("Coordination::GroupsWorker: #{e.class}: #{e.message}")
        raise
      ensure
        release_lock
      end
    end

    private

    def acquire_lock
      Sidekiq.redis { |r| r.set(LOCK_KEY, Time.current.to_i, nx: true, ex: LOCK_TTL) }
    end

    def release_lock
      Sidekiq.redis { |r| r.del(LOCK_KEY) }
    end
  end
end
