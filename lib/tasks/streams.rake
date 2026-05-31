# frozen_string_literal: true

# BUG-251.40 Phase C — operator rake tasks for stream lifecycle cleanup.
#
#   bin/rails streams:audit
#     Read-only sweep. Queries Helix for all open Streams >12h old, classifies them
#     as FUSE / GHOST / OK, prints counts + samples. Never mutates anything.
#
#   bin/rails streams:cleanup_fuse_and_ghost
#   bin/rails streams:cleanup_fuse_and_ghost[true]
#     Dry-run (default) — same output as :audit but emphasises preview-only.
#
#   bin/rails streams:cleanup_fuse_and_ghost[false]
#     Apply. Closes every FUSE + GHOST row via StreamOfflineWorker.new.perform
#     (synchronous — finalize_stream + IRC part + BotScoring + PostStream enqueue).
#     Throttled ~10 closes/sec to keep downstream pipelines stable. Run during a
#     low-traffic window; expect ~5-10 minutes for 500+ rows.
#
# Both tasks delegate to Streams::LifecycleAudit — see service file for the audit
# decision tree, partial-Helix-failure handling, and throttle constants.

namespace :streams do
  desc "Read-only audit of open Stream rows (categorize fuse / ghost / ok via Helix Get-Streams)"
  task audit: :environment do
    Streams::LifecycleAudit.new(dry_run: true).audit_only
  end

  desc "Audit + cleanup fused/ghosted open Stream rows. dry_run defaults to TRUE."
  task :cleanup_fuse_and_ghost, [ :dry_run ] => :environment do |_t, args|
    dry_run = args[:dry_run].nil? ? true : ActiveModel::Type::Boolean.new.cast(args[:dry_run])
    Streams::LifecycleAudit.new(dry_run: dry_run).call
  end
end
