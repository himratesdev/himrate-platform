# frozen_string_literal: true

# External-integration lane (4.3): REAL EventSub management API (list only — creating a
# subscription needs a public HTTPS callback, out of scope for a test lane).
require "rails_helper"
require_relative "live_channel_helper"

RSpec.describe "Twitch EventSub list (real API)", :external, type: :integration do
  before do
    skip "TWITCH_CLIENT_ID/SECRET not set" unless ExternalLiveChannel.app_creds?
  end

  it "lists current app subscriptions without raising" do
    result = Twitch::EventSubService.new.list_subscriptions
    expect(result).not_to be_nil
  end
end
