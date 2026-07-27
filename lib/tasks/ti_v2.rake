# frozen_string_literal: true

# FULL-CHAIN M1 (2026-07-27) — ops verification of the L0 naming-stack invariants on the LIVE,
# DB-merged calibration table (Calibration::Registry.load reads CalibrationConstant overrides). The
# rspec suite (spec/services/calibration/llr_naming_invariants_spec.rb) asserts the SAME bounds on the
# illustrative floor; this task asserts them on whatever a flip's data-write actually produced. Run it
# in EVERY LLR flip runbook, AFTER seeding, BEFORE declaring the flip done: a bad seed that stacks a
# sub-confirmed temporal tier into public naming exits non-zero here (fail-loud), never in production.
namespace :ti_v2 do
  desc "Verify the L0 LLR naming-stack invariants (I1/I2/I3) on the live DB-merged table"
  task verify_llr_invariants: :environment do
    k = Calibration::Registry.load
    tau_gap = Math.log(k.tau_hard / (1.0 - k.tau_hard)) - Math.log(k.pi0 / (1.0 - k.pi0))

    checks = [
      [ "I1  R2+known < τ_gap", k.llr_temporal_r2 + k.llr_known_bot, :<,  tau_gap ],
      [ "I2  R3+known < τ_gap", k.llr_temporal_r3 + k.llr_known_bot, :<,  tau_gap ],
      [ "I3  R4 solo  < τ_gap−1", k.llr_temporal_r4,                :<,  tau_gap - 1.0 ]
    ]

    puts "== L0 LLR naming-stack invariants (live) == τ_gap=#{tau_gap.round(3)} (π0=#{k.pi0} τ_hard=#{k.tau_hard})"
    puts "   LLR table: r2=#{k.llr_temporal_r2} r3=#{k.llr_temporal_r3} r4=#{k.llr_temporal_r4} r7=#{k.llr_temporal_r7} known=#{k.llr_known_bot}"
    failed = checks.reject do |label, lhs, _op, rhs|
      ok = lhs < rhs
      puts format("   %-22s %.3f %s %.3f  → %s", label, lhs, "<", rhs, ok ? "PASS" : "🔴 FAIL")
      ok
    end

    # Informational: r7 IS the designated solo-naming tier (≥ τ_gap by design). Report, don't gate.
    r7_names = k.llr_temporal_r7 >= tau_gap
    puts format("   r7 solo naming tier    %.3f %s %.3f  → %s (informational: R7 is the naming tier)",
                k.llr_temporal_r7, r7_names ? "≥" : "<", tau_gap, r7_names ? "names" : "BELOW-naming (knife-edge/env-parity)")

    if failed.any?
      warn "\n🔴 #{failed.size} naming-stack invariant(s) VIOLATED — a sub-confirmed tier can name. DO NOT proceed with the flip."
      exit 1
    end
    puts "\n🟢 all naming-stack invariants hold — no accidental naming class."
  end
end
