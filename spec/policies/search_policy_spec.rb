# frozen_string_literal: true

require "rails_helper"

# WEB-CONSOLIDATION: finding a channel is navigation — open to guests by code.
RSpec.describe SearchPolicy do
  it "opens search to a guest" do
    expect(described_class.new(nil, :search).search?).to be(true)
  end

  it "opens search to a signed-in user" do
    expect(described_class.new(create(:user), :search).search?).to be(true)
  end
end
