# frozen_string_literal: true

# TASK-085 FR-022 (ADR-085 D-1) — schema migration noop.
#
# PG W-2 fix: Original migration body seeded 12 SignalConfiguration rows inline.
# Per ai-dev-team/CLAUDE.md "Миграции — Нет данных в миграциях", seeding moved to
# db/seeds/chatter_ccv_baselines.rb (auto-loaded from db/seeds.rb).
#
# This file remains as a NOOP migration to preserve schema_migrations history
# (already applied to staging at 20260504; deletion would orphan the row and
# trigger Rails::ActiveRecord::PendingMigrationError on next deploy).
#
# Deployment runbook (per ai-dev-team/prompts/deployment_verification.md):
#   1. kamal app exec 'bin/rails db:migrate' — applies schema migrations (noop here)
#   2. kamal app exec 'bin/rails db:seed' — seeds idempotent data including baselines
#   3. Verify: SignalConfiguration.where(signal_type:'chatter_ccv_ratio',
#                                        param_name:%w[baseline_min baseline_max]).count == 12
#
# Existing staging rows already in place — db:seed re-run is idempotent (find_or_initialize_by).

class SeedChatterCcvBaselines < ActiveRecord::Migration[8.0]
  def up
    # noop — see header comment + db/seeds/chatter_ccv_baselines.rb
  end

  def down
    # noop — companion to up; rollback semantics owned by db/seeds/chatter_ccv_baselines.rb
    # (which is не invoked by db:rollback). Removal of seeded rows = manual SignalConfiguration
    # cleanup task, not migration responsibility per CLAUDE.md.
  end
end
