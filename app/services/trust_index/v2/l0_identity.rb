# frozen_string_literal: true

module TrustIndex
  module V2
    # L0 — per-chatter log-odds posterior p_u + the hard set B_hard (SRS FR-001, Glossary §C
    # «bot_score (p_u)»). Dedups correlated identity signals into ONE posterior per identity via a
    # log-odds sum (not noisy-OR triple-count): logit(p_u) = logit(π0) + Σ_k L_k(u). A silent source
    # contributes 0 (LlrCalibrator). B_hard = {u : p_u ≥ τ_hard} at ≥99% precision — dispute-safe, so
    # the named usernames can be shown. Silent stream → empty set → F_hard = 0 (L2 recalls via deficit).
    class L0Identity
      Chatter = Data.define(:username, :p_u)
      PosteriorSet = Data.define(:chatters, :b_hard)

      # raw — Array of per-chatter signal objects (respond to username + LlrCalibrator signals).
      # k — responds to pi0, tau_hard, and the LLR table (llr_temporal_*, llr_per_user_bot_score, …).
      def self.call(raw, k:)
        logit_pi0 = Math.log(k.pi0 / (1.0 - k.pi0))
        chatters = raw.map do |sig|
          Chatter.new(username: sig.username, p_u: sigmoid(logit_pi0 + LlrCalibrator.sum_llr(sig, k: k)))
        end
        PosteriorSet.new(chatters: chatters, b_hard: chatters.select { |c| c.p_u >= k.tau_hard })
      end

      # Logistic; guards against Float overflow at the tails (exp(-∞)→∞ ⇒ 0.0, exp(∞)→0 ⇒ 1.0).
      def self.sigmoid(logit)
        1.0 / (1.0 + Math.exp(-logit))
      end
      private_class_method :sigmoid
    end
  end
end
