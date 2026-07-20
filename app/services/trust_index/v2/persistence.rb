# frozen_string_literal: true

module TrustIndex
  module V2
    # Persist an Engine::Result → trust_index_histories (v2 columns, engine_version:'v2') + a
    # named_bot_evidence row per B_hard account when C_hard fires (SRS FR-006/§5.1, EC-13 — the plashka
    # MUST be backed by named accounts, dispute-reproducible; ADR DEC-1 persistence.rb). Append-only
    # history (create!, never update). The retired trust_index_score stays null on v2 rows (the model
    # only requires it for engine_version='v1').
    class Persistence
      # ccv: the engine input V (shown viewers) — the Result does not carry it, the SCW call site
      # does (v2_context.v). Persisted so consumers (erv_breakdown{v}, watchlist ccv display/sort,
      # landing shown/real math, /erv derived %) read V off the same row (PR3b gap D-5/w1).
      def self.call(result:, channel:, stream:, calculated_at:, ccv: nil)
        new(result, channel, stream, calculated_at, ccv).call
      end

      def initialize(result, channel, stream, calculated_at, ccv = nil)
        @r = result
        @channel = channel
        @stream = stream
        @at = calculated_at
        @ccv = ccv
      end

      def call
        tih = TrustIndexHistory.create!(tih_attrs)
        persist_evidence(tih) if @r.c_hard
        tih
      end

      private

      def tih_attrs
        { channel: @channel, stream: @stream, calculated_at: @at, engine_version: "v2",
          ccv: @ccv, # V (engine input) — PR3b D-5: consumers read V off the row (nil-safe column)
          erv: round_or_nil(@r.erv), erv_lo: round_or_nil(@r.erv_lo), erv_hi: round_or_nil(@r.erv_hi),
          f_hat: @r.f_hat, f_hat_lo: @r.f_hat_lo, f_hat_hi: @r.f_hat_hi,
          f_hard: @r.f_hard, f_hard_lo: @r.f_hard_lo, f_self: @r.f_self,
          # PR3a (T1-074) — persist the L2 soft breakdown + intervals for /erv erv_breakdown{f_hard,f_soft,f_hat}
          # (Surface 2) + authenticity interval + Q. Columns exist since M1; were unwritten (verified gap D-3).
          f_soft: @r.f_soft, f_soft_lo: @r.f_soft_lo, f_soft_hi: @r.f_soft_hi,
          authenticity: @r.authenticity, authenticity_lo: @r.authenticity_lo, authenticity_hi: @r.authenticity_hi,
          n_frac: @r.n_frac, q_score: @r.q_score, eihc: @r.eihc, rho_obs: @r.rho_obs,
          band_row: @r.band.row, band_sub: @r.band.sub, band_color: @r.band.color,
          reason_codes: @r.reason_codes.map(&:to_h), c_hard: @r.c_hard, c_self: @r.c_self,
          i_event: @r.c_self, # C_self = (I=1); the i_event column mirrors it (SRS §5.1)
          confirmed_anomaly: @r.confirmed_anomaly, cold_start_tier: @r.cold_start_tier,
          confidence_marker: @r.confidence_marker }
      end

      def persist_evidence(tih)
        @r.b_hard.each do |chatter|
          NamedBotEvidence.create!(channel: @channel, stream: @stream, trust_index_history: tih,
                                   username: chatter.username, p_u: chatter.p_u,
                                   evidence_reason: "temporal_cross_channel", calculated_at: @at)
        end
      end

      def round_or_nil(value)
        value&.round
      end
    end
  end
end
