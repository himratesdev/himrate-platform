# frozen_string_literal: true

module TrustIndex
  module V2
    # Inflation event I — the self-history tripwire gating C_self and the F_self arm (SRS FR-013,
    # Glossary §C "C_self / I"). Pure 6-condition conjunction over pre-computed self-referential
    # sub-signals. Fail-safe: I=0 on any ambiguity, on cold-start insufficiency (no self-history),
    # or on a provenance-less real surge (→ widen interval, never accuse). Detects convert-from-honest
    # inflation only (an established honest channel that started inflating).
    class InflationEvent
      Result = Data.define(:i_event, :unattributed_surge)

      # c — responds to: rho_dropped_vs_baseline, v_above_own_trend, raid_window,
      #     chat_arrival_below_floor, no_follower_sub_bump, variance_below_floor_or_plateau,
      #     unattributed_surge, cold_start_tier.
      def self.call(c)
        return Result.new(i_event: false, unattributed_surge: c.unattributed_surge) if suppressed?(c)

        fired = c.rho_dropped_vs_baseline && c.v_above_own_trend && !c.raid_window &&
                c.chat_arrival_below_floor && c.no_follower_sub_bump && c.variance_below_floor_or_plateau
        Result.new(i_event: fired, unattributed_surge: false)
      end

      # No self-history (insufficient) or an unattributed real surge → never fire (never accuse).
      def self.suppressed?(c)
        c.cold_start_tier == "insufficient" || c.unattributed_surge
      end
      private_class_method :suppressed?
    end
  end
end
