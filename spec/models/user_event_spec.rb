# frozen_string_literal: true

require "rails_helper"

RSpec.describe UserEvent, type: :model do
  it "belongs to a user and requires type + occurred_at" do
    expect(build(:user_event)).to be_valid
    expect(build(:user_event, event_type: nil)).not_to be_valid
    expect(build(:user_event, occurred_at: nil)).not_to be_valid
  end

  it "filters by type" do
    user = create(:user) # note: creating a user also emits a `registered` event (callback)
    sub = UserEvent.create!(user: user, event_type: "subscribed", occurred_at: Time.current)
    UserEvent.create!(user: user, event_type: "other", occurred_at: Time.current)

    expect(UserEvent.of_type("subscribed")).to contain_exactly(sub)
  end
end
