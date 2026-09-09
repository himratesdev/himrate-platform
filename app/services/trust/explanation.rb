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

    # Which arms formed the total under the rule that was in force.
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
      }.compact
    end

    def named_params
      @named_params ||= begin
        row = (@tih.reason_codes || []).find do |c|
          (c.is_a?(Hash) ? (c["code"] || c[:code]) : c).to_s == "HARD_NAMED_FRACTION"
        end
        row.is_a?(Hash) ? (row["params"] || row[:params]) : nil
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
        category: stream&.game_name.presence || "default",
        v_bucket: TrustIndex::V2::CellKey.v_bucket(shown),
        chat_mode: TrustIndex::V2::CellKey.chat_mode(@channel&.channel_protection_config),
        language: stream&.language.presence || "default"
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
