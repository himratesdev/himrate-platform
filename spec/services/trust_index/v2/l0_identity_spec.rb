# frozen_string_literal: true

require "rails_helper"

module L0IdentitySpecDoubles
  Sig = Data.define(:username, :temporal_recurrence, :known_bot_hit, :per_user_bot_score,
                    :account_profile_llr, :anti_bot_llr)
  K = Data.define(:pi0, :tau_hard, :llr_temporal_r2, :llr_temporal_r3, :llr_temporal_r4,
                  :llr_temporal_r7, :llr_per_user_bot_score, :llr_known_bot).new(
                    pi0: 0.02, tau_hard: 0.9, llr_temporal_r2: 1.1, llr_temporal_r3: 2.2,
                    llr_temporal_r4: 2.9, llr_temporal_r7: 4.6, llr_per_user_bot_score: 3.9,
                    llr_known_bot: 3.4
                  )
end

RSpec.describe TrustIndex::V2::L0Identity do
  let(:k) { L0IdentitySpecDoubles::K }

  def sig(username, **over)
    base = { username: username, temporal_recurrence: nil, known_bot_hit: false,
             per_user_bot_score: nil, account_profile_llr: 0.0, anti_bot_llr: 0.0 }
    L0IdentitySpecDoubles::Sig.new(**base.merge(over))
  end

  it "maps a silent chatter to the base rate π0 (logit(π0), all L_k=0)" do
    ps = described_class.call([ sig("alice") ], k: k)
    expect(ps.chatters.first.p_u).to be_within(1e-9).of(0.02)
  end

  it "pushes a strongly-flagged chatter above τ_hard into B_hard" do
    ps = described_class.call([ sig("botA", temporal_recurrence: 9, known_bot_hit: true, per_user_bot_score: 1.0) ], k: k)
    expect(ps.chatters.first.p_u).to be > 0.9
    expect(ps.b_hard.map(&:username)).to eq(%w[botA])
  end

  it "keeps a clean chatter out of B_hard and dedups signals as one identity (log-odds sum)" do
    ps = described_class.call([ sig("alice"), sig("bob", temporal_recurrence: 2) ], k: k)
    expect(ps.b_hard).to be_empty
    expect(ps.chatters.size).to eq(2)
  end

  it "handles a silent stream (no chatters) → empty B_hard" do
    ps = described_class.call([], k: k)
    expect(ps.chatters).to be_empty
    expect(ps.b_hard).to be_empty
  end
end
