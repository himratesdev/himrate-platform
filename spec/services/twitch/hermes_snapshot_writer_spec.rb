# frozen_string_literal: true

require "rails_helper"

RSpec.describe Twitch::HermesSnapshotWriter do
  subject(:writer) { described_class.new }

  let(:channel) { create(:channel, twitch_id: "238813810", login: "eliasn97") }
  let!(:stream) { create(:stream, channel: channel, ended_at: nil) }

  def payload(overrides = {})
    { "type" => "viewcount", "viewers" => 41_944,
      "collaboration_status" => "in_collaboration", "collaboration_viewers" => 54_149 }.merge(overrides)
  end

  it "writes a CcvSnapshot with viewers + the collaboration split" do
    expect { writer.write("238813810", payload) }.to change { stream.ccv_snapshots.count }.by(1)

    snap = stream.ccv_snapshots.last
    expect(snap.ccv_count).to eq(41_944)
    expect(snap.collaboration_viewers).to eq(54_149)
    expect(snap.collaboration_status).to eq("in_collaboration")
  end

  it "writes a solo channel with a zero/none collaboration" do
    writer.write("238813810", payload("viewers" => 389, "collaboration_status" => "none", "collaboration_viewers" => 0))

    snap = stream.ccv_snapshots.last
    expect(snap.ccv_count).to eq(389)
    expect(snap.collaboration_viewers).to eq(0)
    expect(snap.collaboration_status).to eq("none")
  end

  it "does NOT write a spurious ccv_count:0 when the push has no viewers key" do
    expect { writer.write("238813810", { "type" => "viewcount", "collaboration_status" => "none" }) }
      .not_to change(CcvSnapshot, :count)
  end

  it "does not write when no channel resolves for the id" do
    expect { writer.write("99999999", payload) }.not_to change(CcvSnapshot, :count)
  end

  it "does not write when the channel has no live stream (ended)" do
    stream.update!(ended_at: 1.hour.ago)
    expect { writer.write("238813810", payload) }.not_to change(CcvSnapshot, :count)
  end

  it "resolves against a fresh cache after #reset_cache (ended stream stops writing)" do
    writer.write("238813810", payload) # caches the live stream
    writer.reset_cache
    stream.update!(ended_at: 1.hour.ago)
    expect { writer.write("238813810", payload) }.not_to change(CcvSnapshot, :count)
  end
end
