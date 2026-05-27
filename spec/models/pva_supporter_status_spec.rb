# frozen_string_literal: true

require "rails_helper"

RSpec.describe PvaSupporterStatus, type: :model do
  subject { build(:pva_supporter_status) }

  it { is_expected.to belong_to(:user) }
  it { is_expected.to validate_presence_of(:channel_id) }
  it { is_expected.to validate_presence_of(:tier) }
  it { is_expected.to validate_inclusion_of(:tier).in_array(described_class::TIERS) }
  it { is_expected.to validate_presence_of(:computed_at) }

  it "is categorical (4 absolute tiers, no numeric public score — BR-006)" do
    expect(described_class::TIERS).to eq(%w[devoted loyal regular active])
  end

  it "maps to the pva_supporter_status table" do
    expect(described_class.table_name).to eq("pva_supporter_status")
  end
end
