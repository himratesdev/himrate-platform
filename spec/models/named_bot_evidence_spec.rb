# frozen_string_literal: true

require "rails_helper"

# T1-074 (TI v2) — NamedBotEvidence: immutable dispute-safe P5 evidence backing the plashka.
RSpec.describe NamedBotEvidence do
  let(:channel) { create(:channel) }
  let(:stream) { create(:stream, channel: channel) }
  let(:tih) { create(:trust_index_history, channel: channel, stream: stream) }

  def evidence(attrs = {})
    described_class.new({
      channel: channel, stream: stream, trust_index_history: tih,
      username: "xqcbot123", p_u: 0.94, evidence_reason: "temporal_cross_channel",
      calculated_at: Time.current
    }.merge(attrs))
  end

  it "validates presence, p_u ∈ [0,1] inclusive, and the required associations" do
    expect(evidence).to be_valid
    expect(evidence(p_u: 0)).to be_valid            # lower boundary
    expect(evidence(p_u: 1)).to be_valid            # upper boundary
    expect(evidence(p_u: 1.5)).not_to be_valid
    expect(evidence(p_u: -0.1)).not_to be_valid
    expect(evidence(username: nil)).not_to be_valid
    expect(evidence(channel: nil)).not_to be_valid
    expect(evidence(trust_index_history: nil)).not_to be_valid
  end

  it "allows a nil stream (live-aggregate evidence has no per-broadcast stream)" do
    expect(evidence(stream: nil)).to be_valid
  end

  it "is append-only — raises on update after creation (dispute-evidence integrity)" do
    rec = evidence.tap(&:save!)
    expect { rec.update!(p_u: 0.5) }.to raise_error(ActiveRecord::ReadOnlyRecord)
  end

  it ".for_history returns the snapshot's evidence ordered by p_u desc" do
    evidence(username: "a", p_u: 0.80).save!
    evidence(username: "b", p_u: 0.99).save!
    expect(described_class.for_history(tih.id).pluck(:username)).to eq(%w[b a])
  end
end
