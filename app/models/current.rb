# frozen_string_literal: true

# Request/job-scoped in-memory state.
# Rails 8 ActiveSupport::CurrentAttributes auto-resets:
#   - HTTP requests via ActionDispatch::Executor
#   - Sidekiq jobs via Rails.executor.wrap (Sidekiq 7+)
#   - Tests via ActiveSupport::CurrentAttributes::TestHelper (auto-included)
#
# Attributes:
#   - signal_config: Hash cache of SignalConfiguration.value_for lookups для
#     избежания амплификации запросов при обогащении Trends response (CR W-3).
#     30-50 lookups per endpoint compress в ~10 unique DB reads + memoized hits.

class Current < ActiveSupport::CurrentAttributes
  attribute :signal_config
end
