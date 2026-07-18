# frozen_string_literal: true

require "rails_helper"

module EihcWeigherSpecDoubles
  Chatter = Data.define(:cluster_delta_k, :cluster_size, :age_gate, :recurrence_gate)
end

RSpec.describe TrustIndex::V2::EihcWeigher do
  def chatter(**over)
    base = { cluster_delta_k: 0.0, cluster_size: 1, age_gate: 1.0, recurrence_gate: 1.0 }
    EihcWeigherSpecDoubles::Chatter.new(**base.merge(over))
  end

  let(:tau_delta) { 0.5 }

  it "gives full weight to an honest low-density cluster (δ_K < τ_δ)" do
    expect(described_class.weight(chatter, tau_delta: tau_delta)).to eq(1.0)
  end

  it "collapses a bot-dense cluster (δ_K ≥ τ_δ) to 1/|K|" do
    w = described_class.weight(chatter(cluster_delta_k: 0.8, cluster_size: 4), tau_delta: tau_delta)
    expect(w).to eq(0.25)
  end

  it "downweights fresh / non-recurring accounts via the age & recurrence gates" do
    w = described_class.weight(chatter(age_gate: 0.5, recurrence_gate: 0.4), tau_delta: tau_delta)
    expect(w).to be_within(1e-9).of(0.2)
  end

  it "guards against a zero cluster size (never divides by zero)" do
    w = described_class.weight(chatter(cluster_delta_k: 0.9, cluster_size: 0), tau_delta: tau_delta)
    expect(w).to eq(1.0)
  end

  it "EIHC sums the effective weights of the (B_hard-stripped) chatters" do
    chatters = [ chatter, chatter(age_gate: 0.5), chatter(cluster_delta_k: 0.6, cluster_size: 2) ]
    expect(described_class.eihc(chatters, tau_delta: tau_delta)).to be_within(1e-9).of(1.0 + 0.5 + 0.5)
  end
end
