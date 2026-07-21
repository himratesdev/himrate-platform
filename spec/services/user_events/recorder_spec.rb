# frozen_string_literal: true

require "rails_helper"

RSpec.describe UserEvents::Recorder do
  let(:user) { create(:user) }

  it "records an event with type + metadata + occurred_at" do
    freeze = Time.utc(2026, 7, 22, 12, 0, 0)
    event = described_class.record(user, "subscribed", { plan: "premium" }, occurred_at: freeze)

    expect(event).to be_persisted
    expect(event.user).to eq(user)
    expect(event.event_type).to eq("subscribed")
    expect(event.metadata).to eq("plan" => "premium")
    expect(event.occurred_at).to eq(freeze)
  end
end
