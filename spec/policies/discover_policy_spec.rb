# frozen_string_literal: true

require "rails_helper"

# WEB-CONSOLIDATION: the home page's live board answers guests by code. The growth screen
# (discover/games) shares the policy class but stays registered-only.
RSpec.describe DiscoverPolicy do
  let(:user) { create(:user) }

  describe "#live?" do
    it "opens the live board to a guest" do
      expect(described_class.new(nil, :discover).live?).to be(true)
    end

    it "opens the live board to a signed-in user" do
      expect(described_class.new(user, :discover).live?).to be(true)
    end
  end

  describe "#games?" do
    it "keeps the growth screen closed to a guest" do
      expect(described_class.new(nil, nil).games?).to be(false)
    end

    it "opens it to a signed-in user asking for their own screen" do
      expect(described_class.new(user, user).games?).to be(true)
    end

    it "denies a record that is not the caller" do
      expect(described_class.new(user, create(:user)).games?).to be(false)
    end
  end
end
