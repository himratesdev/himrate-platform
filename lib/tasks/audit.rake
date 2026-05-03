# frozen_string_literal: true

# TASK-085 FR-024 (ADR-085 D-2): CI gate verifying legal-safe wording compliance.
# bot_wave enum value renamed → anomaly_wave per FR-019 (CLAUDE.md ERV labels v3 strict).
# Task fails build if 'bot_wave' string literal found in app/, spec/, db/seeds/, lib/.
# Prevents future regression after FR-019 migration.
#
# Excludes db/migrate/ — historical migration files may legitimately reference 'bot_wave'
# for rollback support (RenameBotWaveAnomalyType down: anomaly_wave → bot_wave UPDATE).
#
# Integration: invoked from .github/workflows/ci.yml lint job.
# Usage: bundle exec rake audit:verify_no_bot_wave

namespace :audit do
  desc "Verify no 'bot_wave' string literal in app/spec/db/seeds/lib (ADR-085 D-2, BR-012)"
  task :verify_no_bot_wave do
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
end
