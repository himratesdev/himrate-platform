# frozen_string_literal: true

# TASK-085 FR-024 (ADR-085 D-2): CI gate verifying legal-safe wording compliance.
# bot_wave enum value renamed → anomaly_wave per FR-019 (CLAUDE.md ERV labels v3 strict).
# Task fails build if 'bot_wave' string literal found in app/, spec/, db/seeds/, lib/.
# Prevents future regression after FR-019 migration.
#
# Excludes db/migrate/ — historical migration files may legitimately reference 'bot_wave'
# for rollback support (RenameBotWaveAnomalyType down: anomaly_wave → bot_wave UPDATE).
#
# PG W-5 scope note: this gate covers himrate-platform repo ONLY. Companion grep gate
# для himrate-extension repo (frontend anomaly_type strings) tracked separately —
# Release Checklist gates platform deploy за extension PR-2 merge + Chrome Web Store
# review timing. Cross-repo CI sync = future work (separate task in Notion).
#
# Integration: invoked from .github/workflows/ci.yml lint job.
# Usage: bundle exec rake audit:verify_no_bot_wave
#        bundle exec rake audit:verify_no_bot_wave_in_db   # post-deploy DB check (PG W-4)

namespace :audit do
  desc "Verify no 'bot_wave' string literal in app/spec/db/seeds/lib (ADR-085 D-2, BR-012)"
  task :verify_no_bot_wave do
    # CR N-4: backtick shell exec acceptable here — `paths` is a hardcoded literal array,
    # never user input. Defense-in-depth: pattern is a fixed string, --include globs are static.
    # No command injection surface. Promoting to Open3 would obscure intent without security gain.
    paths = %w[app spec db/seeds lib]
    matches = paths.flat_map do |path|
      next [] unless Dir.exist?(path)

      output = `grep -rn --include='*.rb' --include='*.yml' --include='*.json' "['\\"]bot_wave['\\"]" #{path} 2>/dev/null`
      output.lines
    end

    if matches.any?
      puts "FAIL: 'bot_wave' string literal found (BR-012 legal-safe wording violation):"
      matches.each { |line| puts "  #{line.chomp}" }
      puts ""
      puts "Per ADR-085 D-2 + CLAUDE.md ERV labels v3 — replace 'bot_wave' with 'anomaly_wave'."
      exit 1
    else
      puts "✓ No 'bot_wave' references found in app/, spec/, db/seeds/, lib/ (ADR-085 D-2 compliant)"
    end
  end

  # PG W-4: post-deploy verification — closes rolling-deploy race window.
  # Migration #1 (RenameBotWaveAnomalyType) переписывает existing rows, но OLD container
  # может писать anomaly_type='bot_wave' в transient окно между db:migrate и cutover.
  # Such rows would be silently dropped из AnomalyAlertsPresenter (PRESENTABLE_ANOMALY_TYPES
  # содержит 'anomaly_wave', не 'bot_wave') — graceful degradation, but still a data leak.
  #
  # Run после kamal deploy completes. If any rows found, applies same UPDATE как migration #1.
  # Per ai-dev-team/prompts/deployment_verification.md §17.
  desc "Post-deploy: verify no 'bot_wave' anomaly_type rows leaked through rolling cutover (PG W-4)"
  task verify_no_bot_wave_in_db: :environment do
    legacy_count = Anomaly.where(anomaly_type: "bot_wave").count

    if legacy_count.zero?
      puts "✓ No legacy 'bot_wave' anomaly rows in DB (W-4 OK — rolling cutover clean)"
    else
      puts "WARN: #{legacy_count} legacy 'bot_wave' anomaly rows found — applying rename..."
      updated = Anomaly.where(anomaly_type: "bot_wave").update_all(anomaly_type: "anomaly_wave")
      puts "✓ Renamed #{updated} rows bot_wave → anomaly_wave (W-4 healed)"
      puts "Investigate: which container/window wrote these rows post-migrate?"
    end
  end
end
