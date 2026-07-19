# frozen_string_literal: true

require "rails_helper"

module L1SubtractSpecDoubles
  Chatter = Data.define(:username, :p_u)
  PosteriorSet = Data.define(:chatters, :b_hard)
end

RSpec.describe TrustIndex::V2::L1Subtract do
  def posterior_set(b_hard_probs)
    b = b_hard_probs.each_with_index.map { |p, i| L1SubtractSpecDoubles::Chatter.new(username: "b#{i}", p_u: p) }
    L1SubtractSpecDoubles::PosteriorSet.new(chatters: b, b_hard: b)
  end

  it "F_hard = Σ p_u over B_hard, with P5 ≤ F_hard ≤ P95 (dispute-safe interval)" do
    hf = described_class.call(posterior_set(Array.new(300, 0.95)))
    expect(hf.f_hard).to be_within(1e-6).of(285.0)
    expect(hf.f_hard_lo).to be < hf.f_hard
    expect(hf.f_hard).to be < hf.f_hard_hi
  end

  it "empty B_hard → F_hard = 0 (silent stream / no named bots)" do
    hf = described_class.call(posterior_set([]))
    expect([ hf.f_hard, hf.f_hard_lo, hf.f_hard_hi ]).to eq([ 0.0, 0.0, 0.0 ])
  end
end
