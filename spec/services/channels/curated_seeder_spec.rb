# frozen_string_literal: true

require "rails_helper"

RSpec.describe Channels::CuratedSeeder do
  let(:helix) { instance_double(Twitch::HelixClient) }

  def helix_user(id:, login:)
    {
      "id" => id, "login" => login, "display_name" => login.capitalize,
      "broadcaster_type" => "affiliate", "description" => "bio",
      "profile_image_url" => "https://cdn.twitch/#{login}.png"
    }
  end

  it "pins a new curated channel as monitored + pinned with metadata" do
    allow(helix).to receive(:get_users).with(logins: [ "streamerone" ]).and_return([ helix_user(id: "1", login: "streamerone") ])

    result = described_class.call(logins: [ "StreamerOne" ], helix: helix) # mixed case normalized

    channel = Channel.find_by(twitch_id: "1")
    expect(channel).to have_attributes(
      login: "streamerone", is_monitored: true, is_pinned: true,
      display_name: "Streamerone", broadcaster_type: "affiliate"
    )
    expect(channel.metadata_synced_at).to be_present
    expect(result.pinned).to eq(1)
    expect(result.unresolved).to be_empty
  end

  it "flips an already-discovered channel to pinned (idempotent upsert by twitch_id)" do
    existing = create(:channel, twitch_id: "2", login: "disco", is_monitored: true, is_pinned: false)
    allow(helix).to receive(:get_users).with(logins: [ "disco" ]).and_return([ helix_user(id: "2", login: "disco") ])

    described_class.call(logins: [ "disco" ], helix: helix)

    expect(existing.reload.is_pinned).to be(true)
    expect(Channel.where(twitch_id: "2").count).to eq(1) # upsert, not duplicate
  end

  it "logs + skips logins Helix can't resolve (banned/renamed) without creating a channel" do
    allow(helix).to receive(:get_users).with(logins: [ "ghostuser" ]).and_return([])

    result = described_class.call(logins: [ "ghostuser" ], helix: helix)

    expect(result.unresolved).to eq([ "ghostuser" ])
    expect(result.pinned).to eq(0)
    expect(Channel.where(login: "ghostuser")).to be_empty
  end

  it "skips a batch on transient Helix failure (nil) without raising — re-runnable" do
    allow(helix).to receive(:get_users).and_return(nil)

    expect { described_class.call(logins: [ "x" ], helix: helix) }.not_to raise_error
    expect(Channel.count).to eq(0)
  end

  it "dedups + normalizes the login list before querying Helix" do
    allow(helix).to receive(:get_users).with(logins: [ "dup" ]).and_return([ helix_user(id: "9", login: "dup") ])

    described_class.call(logins: [ "Dup", "dup", " DUP ", "" ], helix: helix)

    expect(helix).to have_received(:get_users).with(logins: [ "dup" ]).once
  end

  it "drops malformed logins up front (would 400 the batch) and reports them as unresolved" do
    allow(helix).to receive(:get_users).with(logins: [ "validone" ]).and_return([ helix_user(id: "5", login: "validone") ])

    result = described_class.call(logins: [ "validone", "bad login!", "way_too_long_username_exceeding_limit" ], helix: helix)

    expect(result.pinned).to eq(1)
    expect(result.unresolved).to include("bad login!", "way_too_long_username_exceeding_limit")
    expect(helix).to have_received(:get_users).with(logins: [ "validone" ]).once
  end

  it "loads the committed seed list from db/seeds/curated_channels.yml" do
    seed = described_class.load_seed
    expect(seed).to be_an(Array)
    expect(seed).to include("egorkreed")
    expect(seed.size).to be >= 78
  end
end
