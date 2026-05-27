# frozen_string_literal: true

require "rails_helper"

RSpec.describe PersonalAnalyticsPolicy do
  let(:user) { create(:user) }

  it "permits a registered user to view their own analytics (record == self)" do
    expect(described_class.new(user, user).overview?).to be(true)
  end

  it "denies a guest (no current_user)" do
    expect(described_class.new(nil, user).overview?).to be(false)
  end

  it "denies viewing another user's analytics (ownership)" do
    other = create(:user)
    expect(described_class.new(user, other).overview?).to be(false)
  end
end
