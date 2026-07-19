# frozen_string_literal: true

require "set"

module TrustIndex
  module V2
    # V2 engine orchestrator (SRS §2, ADR DEC-1). Runs L0→L4 STRICTLY sequentially — each layer only
    # ADDs fraud and the single reconcile is L3's max, so the anti-convex-average guarantee is
    # structural (no weighted-average node). Reads a pre-assembled Context (ContextBuilder) → pure
    # orchestration, testable without CH/PG. Emits V2::Engine::Result; #to_headline_payload adapts it
    # to the engine-agnostic publish contract (DEC-7) so SignalComputeWorker never reads fields directly.
    class Engine
      SelfCtx = Data.define(:eligible, :v, :eihc, :rho_self_lo)
      EmitCtx = Data.define(:v, :n_chat_eff, :q, :i_event, :raid_window, :cold_start_tier,
                            :named_count, :self_history_stable, :chatter_quality_high,
                            :stream_count, :unattributed_surge, :thin_sample)

      Result = Data.define(:erv, :erv_lo, :erv_hi, :authenticity, :a_hat, :n_frac, :band,
                           :reason_codes, :confirmed_anomaly, :cold_start_tier, :confidence_marker,
                           :c_hard, :c_self, :axes, :eihc, :rho_obs, :f_hat, :f_hat_lo, :f_hat_hi,
                           :f_hard, :f_hard_lo, :f_self, :b_hard, :engine_version) do
        # DEC-7 adapter — the engine maps its own fields to the publish payload; SCW calls this.
        def to_headline_payload
          { erv: erv, erv_interval: { lo: erv_lo, hi: erv_hi }, authenticity: authenticity,
            axes: axes.to_h, band: band.to_h, reason_codes: reason_codes.map(&:to_h),
            confirmed_anomaly: { shown: confirmed_anomaly }, cold_start_tier: cold_start_tier,
            confidence_marker: confidence_marker, engine_version: engine_version }
        end
      end

      def self.compute(context:, k:)
        new(context, k).compute
      end

      def initialize(context, k)
        @ctx = context
        @k = k
      end

      def compute
        post = L0Identity.call(@ctx.raw_chatters, k: @k)
        hard = L1Subtract.call(post)
        soft = L2Presume.call(raw: @ctx.raw_chatters, b_hard_usernames: names(post),
                              v: @ctx.v, cell: @ctx.cell, k: @k)
        fraud = L3Fuse.call(hard: hard, soft: soft, self_ctx: self_ctx(soft))
        emit = L4Emit.call(hard: hard, soft: soft, fraud: fraud, ctx: emit_ctx(post), k: @k)
        Result.new(**emit.to_h, **extras(post, hard, soft, fraud, emit))
      end

      private

      def names(post)
        post.b_hard.map(&:username).to_set
      end

      def self_ctx(soft)
        eligible = @ctx.clean_self_history && @ctx.i_event && !@ctx.raid_window
        SelfCtx.new(eligible: eligible, v: @ctx.v, eihc: soft.eihc, rho_self_lo: @ctx.rho_self_lo)
      end

      def emit_ctx(post)
        EmitCtx.new(v: @ctx.v, n_chat_eff: @ctx.n_chat_eff, q: @ctx.q, i_event: @ctx.i_event,
                    raid_window: @ctx.raid_window, cold_start_tier: @ctx.cold_start_tier,
                    named_count: post.b_hard.size, self_history_stable: @ctx.self_history_stable,
                    chatter_quality_high: @ctx.chatter_quality_high, stream_count: @ctx.stream_count,
                    unattributed_surge: @ctx.unattributed_surge, thin_sample: @ctx.thin_sample)
      end

      def extras(post, hard, soft, fraud, emit)
        { axes: AxesBuilder.call(authenticity: emit.authenticity, reputation: @ctx.reputation,
                                 rho_obs: soft.rho_obs, cps: @ctx.cps),
          eihc: soft.eihc, rho_obs: soft.rho_obs, f_hat: fraud.f_hat, f_hat_lo: fraud.f_hat_lo,
          f_hat_hi: fraud.f_hat_hi, f_hard: hard.f_hard, f_hard_lo: hard.f_hard_lo,
          f_self: fraud.f_self, b_hard: post.b_hard, engine_version: "v2" }
      end
    end
  end
end
