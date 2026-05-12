# frozen_string_literal: true

# TASK-086 FR-031 (partial status): raised by CleanupWorker#batched_loop when a
# batched DELETE is interrupted by `SET LOCAL statement_timeout` (PG raises
# ActiveRecord::QueryCanceled) AFTER at least one batch already committed. Carries
# the number of rows deleted so far so the cleanup_audit_logs row can record
# status=partial with an accurate deleted_count instead of status=error/0.
#
# If ZERO progress was made before the timeout, batched_loop re-raises the original
# QueryCanceled (→ status=error) — there is nothing partial about it.

module Cleanup
  class PartialRunError < StandardError
    attr_reader :deleted_count

    def initialize(deleted_count)
      @deleted_count = deleted_count.to_i
      super("cleanup batch interrupted by statement_timeout after #{@deleted_count} rows")
    end
  end
end
