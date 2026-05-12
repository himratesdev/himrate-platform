# frozen_string_literal: true

# TASK-086 FR-039/013: one-shot historical cleanup used by `rake cleanup:initial_backfill`.
# Chunked DELETE with SET LOCAL statement_timeout='30s' + sleep(0.05)/batch to keep
# the production DB unstressed. dry_run prints a preview (counts + sample) and does nothing.
#
# TIH path respects the conservation rule (final/live/null-stream rows untouched) —
# same single-SQL window function as CleanupWorker#delete_intermediate_tih.

module Cleanup
  class BackfillRunner
    BATCH_SIZE = 1_000
    STATEMENT_TIMEOUT = "30s"
    THROTTLE_SECONDS = 0.05

    TIH_DELETE_SQL = <<~SQL.squish.freeze
      DELETE FROM trust_index_histories tih WHERE tih.id IN (
        SELECT id FROM (
          SELECT t.id, ROW_NUMBER() OVER (PARTITION BY t.stream_id ORDER BY t.calculated_at DESC, t.id DESC) AS rn
          FROM trust_index_histories t JOIN streams s ON s.id = t.stream_id
          WHERE s.ended_at IS NOT NULL AND s.ended_at < $1
        ) ranked WHERE rn > 1 LIMIT 1000
      )
    SQL

    def self.run_tih(cutoff:, dry_run:)
      if dry_run
        puts "[DRY-RUN] tih: would prune intermediate TIH for ended streams (cutoff=#{cutoff.iso8601})."
        puts "[DRY-RUN] eligible-or-fewer TIH rows (joined ended streams): #{TrustIndexHistory.joins(:stream).where.not(streams: { ended_at: nil }).where('streams.ended_at < ?', cutoff).count}"
        puts "[DRY-RUN] sample stream IDs (first 10): #{Stream.where.not(ended_at: nil).where('ended_at < ?', cutoff).limit(10).pluck(:id).join(', ')}"
        puts "[DRY-RUN] re-run with [tih,false] for the actual cleanup."
        return 0
      end

      total = chunked_loop { ApplicationRecord.connection.exec_update(TIH_DELETE_SQL, "cleanup:initial_backfill[tih]", [ cutoff ]) }
      puts "Done: #{total} intermediate trust_index_histories deleted."
      total
    end

    def self.run_table(model:, cutoff:, dry_run:)
      if dry_run
        puts "[DRY-RUN] #{model.table_name}: would delete rows older than #{cutoff.iso8601}."
        puts "[DRY-RUN] eligible rows: #{model.where("#{model.table_name}.timestamp < ?", cutoff).count}"
        puts "[DRY-RUN] re-run with [#{model.table_name},false] for the actual cleanup."
        return 0
      end

      total = chunked_loop { model.where("#{model.table_name}.timestamp < ?", cutoff).limit(BATCH_SIZE).delete_all }
      puts "Done: #{total} #{model.table_name} deleted."
      total
    end

    def self.chunked_loop
      total = 0
      loop do
        affected = ApplicationRecord.transaction do
          ApplicationRecord.connection.execute("SET LOCAL statement_timeout = '#{STATEMENT_TIMEOUT}'")
          yield
        end
        total += affected
        puts "  ... #{total} deleted" if total.positive? && (total % (BATCH_SIZE * 10)).zero?
        break if affected < BATCH_SIZE

        sleep(THROTTLE_SECONDS)
      end
      total
    end

    private_class_method :chunked_loop
  end
end
