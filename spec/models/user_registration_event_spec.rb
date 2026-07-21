# frozen_string_literal: true

require "rails_helper"

# Email-marketing foundation: every new user must leave a `registered` lifecycle
# event — the substrate action-triggered campaigns build on.
RSpec.describe User, "registration event", type: :model do
  it "records exactly one `registered` event on creation, tagged with the email source" do
    user = create(:user, email_source: "twitch")

    events = UserEvent.where(user: user, event_type: UserEvent::REGISTERED)
    expect(events.count).to eq(1)
    expect(events.first.metadata).to eq("email_source" => "twitch")
  end

  it "does not record a new event on update" do
    user = create(:user)
    expect { user.update!(username: "renamed") }
      .not_to change { UserEvent.where(user: user, event_type: UserEvent::REGISTERED).count }
  end

  it "never breaks signup if event recording fails" do
    allow(UserEvents::Recorder).to receive(:record).and_raise(StandardError, "db down")

    expect { create(:user) }.not_to raise_error
  end
end
