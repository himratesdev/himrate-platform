# frozen_string_literal: true

require "rails_helper"

# T1-074 (TI v2) — NamedBotEvidence: immutable dispute-safe P5 evidence backing the plashka.
RSpec.describe NamedBotEvidence do
  let(:stream) { create(:stream) }

  def evidence(attrs = {})
    described_class.new({
      stream: stream, username: "xqcbot123", p_u: 0.94,
      evidence_reason: "HARD_NAMED_FRACTION", calculated_at: Time.current
    }.merge(attrs))
  end

  it "validates presence, p_u ∈ [0,1], and username uniqueness per stream" do
    expect(evidence).to be_valid
    expect(evidence(p_u: 1.5)).not_to be_valid
    expect(evidence(username: nil)).not_to be_valid
    evidence.save!
    expect(evidence(p_u: 0.9)).not_to be_valid # dup username in same stream
  end

  it "is append-only — raises on update after creation (dispute-evidence integrity)" do
    rec = evidence.tap(&:save!)
    expect { rec.update!(p_u: 0.5) }.to raise_error(ActiveRecord::ReadOnlyRecord)
  end

  it ".for_stream returns the stream's evidence ordered by p_u desc" do
    evidence(username: "a", p_u: 0.80).save!
    evidence(username: "b", p_u: 0.99).save!
    expect(described_class.for_stream(stream.id).pluck(:username)).to eq(%w[b a])
  end
end
