# frozen_string_literal: true

# TI v2 per-cell honest ρ* re-seed — server-side replacement for the retired GitHub-Actions pair
# ti-v2-shadow-mine.yml + ti-v2-rho-reseed.yml. Method and safety: Calibration::Reseed (pure) +
# Calibration::ReseedCorpus (read-only loader over trust_index_histories).
#
#   bin/rails calibration:reseed                  # dryrun (default): prints the plan, writes NOTHING
#   CONFIRM_RESEED=yes bin/rails 'calibration:reseed[apply]'
#                                                 # writes the applicable cells in ONE transaction and a
#                                                 # restore snapshot to storage/calibration/ first
#   bin/rails 'calibration:reseed_restore[storage/calibration/reseed-….json]'
#
# Corpus knobs (ENV, all optional): RESEED_SINCE (ISO8601) | RESEED_WINDOW_DAYS (7) | RESEED_IO_BUDGET_MB (900)
#   | RESEED_MIN_V (50) | RESEED_TIMEOUT_S (300). Plan knobs: RESEED_MIN_CHANNELS (8, never below 3 —
#   fewer votes than that get no quantiles at all and the run refuses).
# ⚠ apply changes the deficit baseline — and therefore AMBER/YELLOW exposure — for every channel in the
#   touched cells. PO decision only; always read the dryrun first.
namespace :calibration do
  desc "Re-seed per-cell honest ρ* from persisted TI v2 verdicts (mode: dryrun|apply; apply needs CONFIRM_RESEED=yes)"
  task :reseed, [ :mode ] => :environment do |_, args|
    mode = args[:mode].presence || "dryrun"
    corpus_opts = {
      since: ENV["RESEED_SINCE"].presence&.then { |s| Time.iso8601(s) },
      window_days: (ENV["RESEED_WINDOW_DAYS"] || 7).to_f,
      io_budget_mb: (ENV["RESEED_IO_BUDGET_MB"] || 900).to_f,
      min_v: (ENV["RESEED_MIN_V"] || 50).to_f,
      statement_timeout_s: (ENV["RESEED_TIMEOUT_S"] || 300).to_i
    }
    plan_opts = ENV["RESEED_MIN_CHANNELS"].present? ? { min_channels: ENV["RESEED_MIN_CHANNELS"].to_i } : {}

    Calibration::Reseed.run(
      mode: mode, confirm: ENV[Calibration::Reseed::APPLY_CONFIRM_ENV],
      snapshot_dir: ENV["RESEED_SNAPSHOT_DIR"].presence,
      corpus_loader: -> { Calibration::ReseedCorpus.new(**corpus_opts).load },
      **plan_opts
    )
  rescue Calibration::Reseed::Refused, ArgumentError => e
    abort "calibration:reseed — #{e.message}"
  end

  desc "Restore the cells an apply snapshot names to their pre-apply values (deletes cells apply created)"
  task :reseed_restore, [ :snapshot ] => :environment do |_, args|
    path = args[:snapshot].presence or abort("usage: bin/rails 'calibration:reseed_restore[path/to/reseed-….json]'")
    abort "no such snapshot: #{path}" unless File.exist?(path)

    n = Calibration::Reseed.restore!(path)
    puts "restored #{n} cell(s) from #{path}"
  end
end
