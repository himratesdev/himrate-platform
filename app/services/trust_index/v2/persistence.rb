# frozen_string_literal: true

module TrustIndex
  module V2
    # Persist an Engine::Result → trust_index_histories (v2 columns, engine_version:'v2') + a
    # named_bot_evidence row per B_hard account when C_hard fires (SRS FR-006/§5.1, EC-13 — the plashka
    # MUST be backed by named accounts, dispute-reproducible; ADR DEC-1 persistence.rb). Append-only
    # history (create!, never update). The retired trust_index_score stays null on v2 rows (the model
    # only requires it for engine_version='v1').
    class Persistence
      def self.call(result:, channel:, stream:, calculated_at:)
        new(result, channel, stream, calculated_at).call
      end

      def initialize(result, channel, stream, calculated_at)
        @r = result
        @channel = channel
        @stream = stream
        @at = calculated_at
      end

      def call
        tih = TrustIndexHistory.create!(tih_attrs)
        persist_evidence(tih) if @r.c_hard
        tih
      end

      private

      def tih_attrs
        { channel: @channel, stream: @stream, calculated_at: @at, engine_version: "v2",
          erv: round_or_nil(@r.erv), erv_lo: round_or_nil(@r.erv_lo), erv_hi: round_or_nil(@r.erv_hi),
          f_hat: @r.f_hat, f_hard: @r.f_hard, f_hard_lo: @r.f_hard_lo, f_self: @r.f_self,
          authenticity: @r.authenticity, n_frac: @r.n_frac, eihc: @r.eihc, rho_obs: @r.rho_obs,
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
