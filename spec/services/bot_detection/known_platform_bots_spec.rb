# frozen_string_literal: true

require "rails_helper"

RSpec.describe BotDetection::KnownPlatformBots do
  it "recognizes known platform bots case-insensitively" do
    expect(described_class.utility?("nightbot")).to be true
    expect(described_class.utility?("NightBot")).to be true
    expect(described_class.utility?("streamelements")).to be true
    expect(described_class.utility?("moobot")).to be true
  end

  it "does NOT allowlist impersonators (exact-match is evasion-safe — Twitch usernames are unique)" do
    expect(described_class.utility?("nightbot_2")).to be false
    expect(described_class.utility?("streamelements_clone")).to be false
  end

  it "does not allowlist ordinary/spam users or nil" do
    expect(described_class.utility?("trafi_kroki")).to be false
    expect(described_class.utility?("")).to be false
    expect(described_class.utility?(nil)).to be false
  end
end
