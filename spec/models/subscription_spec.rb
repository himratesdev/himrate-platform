# frozen_string_literal: true

require "rails_helper"

RSpec.describe Subscription do
  let(:user) { create(:user) }

  it "accepts the two known plan_types and nil (legacy/seeded rows)" do
    %w[per_channel promo].each do |pt|
      expect(described_class.new(user: user, tier: "premium", plan_type: pt)).to be_valid
    end
    expect(described_class.new(user: user, tier: "premium", plan_type: nil)).to be_valid
  end

  it "rejects an unknown plan_type and an unknown tier" do
    expect(described_class.new(user: user, tier: "premium", plan_type: "monthly")).not_to be_valid
    expect(described_class.new(user: user, tier: "gold", plan_type: "promo")).not_to be_valid
  end

  it ".active returns only is_active rows" do
    on  = described_class.create!(user: user, tier: "premium", plan_type: "promo", started_at: Time.current, is_active: true)
    described_class.create!(user: user, tier: "premium", plan_type: "promo", started_at: Time.current, is_active: false)

    expect(described_class.active).to contain_exactly(on)
  end
end
