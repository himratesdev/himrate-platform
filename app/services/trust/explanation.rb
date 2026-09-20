# frozen_string_literal: true

module Trust
  # The verdict, taken apart — the block the card was missing and the reason a verdict is worth
  # paying for. Turns one persisted snapshot into "shown N, subtracted X for this, Y for that,
  # real ≈ Z", with the numbers each subtraction rests on.
  #
  # HONEST ABOUT THE ARITHMETIC. The engine does NOT stack the arms into a tidy waterfall: L3 fuses
  # them as `max(F_hard + F_soft, F_self)` under the co-windowed convention and as
  # `max(F_hard, F_soft, F_self)` under the cumulative one — because the named-account arm and the
  # silent-deficit arm count disjoint populations while the self-history arm overlaps both. So the
  # payload names the rule (`fusion.mode`), marks which arms actually formed the total
  # (`applied`), and still reports the ones that did not — a measured-but-not-decisive arm is
  # information, not noise. Drawing three sequential minus signs would be a prettier lie.
  #
  # Everything here is derived from columns already persisted on the snapshot; the one lookup is the
  # calibration baseline (ρ*), resolved through the SAME key the engine used (TrustIndex::V2::CellKey)
  # so "below the norm" is measured against the norm the verdict actually used.
  class Explanation
    def self.call(tih, channel: nil)
      new(tih, channel: channel).call
    end

    def initialize(tih, channel: nil)
      @tih = tih
      @channel = channel || tih&.channel
    end

    def call
      return nil unless @tih && shown.positive?

      {
        shown: shown,
        real: interval(@tih.erv, @tih.erv_lo, @tih.erv_hi),
        authenticity: interval(@tih.authenticity, @tih.authenticity_lo, @tih.authenticity_hi),
        fusion: fusion,
        arms: arms,
        chat: chat,
        confidence: confidence,
        engine_version: @tih.engine_version
      }
    end

    private

    def shown = @tih.ccv.to_i

    def f_hard = @tih.f_hard.to_f
    def f_soft = @tih.f_soft.to_f
    def f_self = @tih.f_self.to_f

    # "windowed" is the co-windowed convention, which is exactly the regime where L3 adds the
    # disjoint arms instead of taking the largest (both ride the same flag).
    def sum_disjoint? = @tih.rho_convention.to_s == "windowed"

    def fusion
      applied = applied_arms
      {
        mode: sum_disjoint? ? "sum" : "max",
        total: round1(@tih.f_hat),
        lo: round1(@tih.f_hat_lo),
        hi: round1(@tih.f_hat_hi),
        applied: applied
      }
    end

    # Which arms formed the total under the rule that was in force. Pure arithmetic on the persisted
    # amounts: ERV = V − F̂ subtracts every arm that formed F̂, including a named arm the verdict
    # declined to accuse on — so «applied» must say so, or the card greys an amount that WAS taken off
    # (see `set_aside` on the named arm for the accusation side).
    def applied_arms
      if sum_disjoint?
        return [ "self_history" ] if f_self > (f_hard + f_soft)

        %w[named deficit].select { |k| (k == "named" ? f_hard : f_soft).positive? }
      else
        best = { "named" => f_hard, "deficit" => f_soft, "self_history" => f_self }.max_by { |_, v| v }
        best.last.positive? ? [ best.first ] : []
      end
    end

    def arms
      applied = applied_arms
      [ named_arm, deficit_arm, self_history_arm ].compact.map { |a| a.merge(applied: applied.include?(a[:kind])) }
    end

    # Accounts the engine named individually (B_hard). `count`/`share_pct` come from the reason
    # code's own params — the engine already published them there, and re-deriving the roster size
    # from n_frac would divide by zero on a clean channel.
    def named_arm
      return nil if f_hard.zero? && !named_params

      p = named_params || {}
      {
        kind: "named",
        amount: round1(f_hard),
        lo: round1(@tih.f_hard_lo),
        accounts: p["n"] || p[:n],
        share_of_chat_pct: p["pct"] || p[:pct]
      }.compact.merge(set_aside_payload)
    end

    # DETECTION-AUDIT 2026-09-19 (CR iter-2 MF-2). Below the named-fraction roster floor the engine
    # still subtracts the named accounts from ERV (identity-level evidence) but declines to ACCUSE on a
    # fraction of a 1-4 person chat. The amount stays `applied` — it WAS taken off, and greying it while
    # ERV = V − F̂ still counts it would put arithmetic on the public card that does not add up. This
    # pair says the other half: draw the «−X» muted, with the reason in words. Copy is server-resolved
    # in the request locale, like `erv_label` and the reason texts — the card carries no bundle.
    # Nothing is emitted unless the row can prove it: n_chat_eff present (NULL on rows persisted before
    # the column existed → no keys at all, payload byte-identical) and no HARD_NAMED_FRACTION.
    def set_aside_payload
      return {} unless named_set_aside?

      {
        set_aside: true,
        set_aside_note: I18n.t("explanation.named_set_aside", n: @tih.n_chat_eff.to_i, default: nil)
      }.compact
    end

    def named_set_aside?
      return false if @tih.n_chat_eff.nil? || named_reason

      floor = named_fraction_roster_floor
      !floor.nil? && @tih.n_chat_eff.to_i < floor
    end

    # The live floor, read the way L4 reads it (Calibration::Registry → chard_frac_roster_min), so the
    # card and the verdict agree on where "too small a chat" starts. nil when it cannot be read — then
    # nothing is marked set aside.
    def named_fraction_roster_floor
      k = Calibration::Registry.load
      k.respond_to?(:chard_frac_roster_min) ? k.chard_frac_roster_min.to_f : nil
    rescue StandardError => e
      Rails.logger.warn("Trust::Explanation roster floor read failed: #{e.class}: #{e.message}")
      nil
    end

    def named_params
      row = named_reason
      row.is_a?(Hash) ? (row["params"] || row[:params]) : nil
    end

    # The engine's own statement that the named arm accuses. Checked on the CODE, not on params, so a
    # reason persisted without params still counts. nil when absent (memoized either way).
    def named_reason
      return @named_reason if defined?(@named_reason)

      @named_reason = (@tih.reason_codes || []).find do |c|
        (c.is_a?(Hash) ? (c["code"] || c[:code]) : c).to_s == "HARD_NAMED_FRACTION"
      end
    end

    # The silent arm: viewers that never write. Measured as the gap between how much of the audience
    # actually writes here and how much writes in comparable channels.
    def deficit_arm
      return nil if f_soft.zero? && @tih.rho_obs.nil?

      {
        kind: "deficit",
        amount: round1(f_soft),
        lo: round1(@tih.f_soft_lo),
        hi: round1(@tih.f_soft_hi),
        observed: share(@tih.rho_obs&.to_f),
        expected: expected_share
      }.compact
    end

    # The channel measured against its own past, not against anyone else.
    def self_history_arm
      return nil if f_self.zero?

      { kind: "self_history", amount: round1(f_self) }
    end

    def chat
      {
        writers_effective: @tih.eihc&.to_f&.round,
        quality: @tih.q_score&.to_f,
        named_fraction: @tih.n_frac&.to_f,
        # The roster that fraction divides by — «0.44» reads very differently over 2 chatters than
        # over 200 (CR iter-1 SF-3). NULL on rows persisted before the column existed → key omitted,
        # so those payloads are unchanged.
        roster: @tih.n_chat_eff&.to_i,
        convention: @tih.rho_convention
      }.compact
    end

    def confidence
      {
        marker: @tih.confidence_marker,
        cold_start_tier: @tih.cold_start_tier,
        # How wide the answer is, as a share of the shown online — the honest reason a range is wide.
        interval_pct: interval_pct
      }.compact
    end

    def interval_pct
      return nil if @tih.erv_lo.nil? || @tih.erv_hi.nil? || shown.zero?

      ((@tih.erv_hi.to_i - @tih.erv_lo.to_i) / shown.to_f * 100).round(1)
    end

    # ── the calibration baseline ────────────────────────────────────────────
    # Same cell key the engine used. `calibrated: false` means we are quoting an illustrative default
    # rather than a measured peer group — the card must say so instead of implying a measurement.
    def expected_share
      cell = resolve_cell
      return nil unless cell

      share(cell.rho_star.to_f)&.merge(calibrated: !!cell.calibrated)
    end

    def resolve_cell
      stream = @tih.stream || @channel&.streams&.order(started_at: :desc)&.first
      TrustIndex::V2::CellResolver.call(
        **TrustIndex::V2::CellKey.for(
          stream: stream, v: shown,
          protection_config: @channel&.channel_protection_config
        )
      )
    rescue StandardError => e
      Rails.logger.warn("Trust::Explanation cell resolve failed: #{e.class}: #{e.message}")
      nil
    end

    # A share the reader can hold in their head: "roughly one viewer in N writes".
    def share(value)
      return nil if value.nil? || value <= 0

      { share: value.round(4), one_in: (1.0 / value).round(1) }
    end

    def interval(value, lo, hi)
      return nil if value.nil?

      { value: value.to_f.round(2), lo: lo&.to_f&.round(2), hi: hi&.to_f&.round(2) }.compact
    end

    def round1(value) = value&.to_f&.round(1)
  end
end
