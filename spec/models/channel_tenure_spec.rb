# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChannelTenure, type: :model do
  subject { build(:channel_tenure) }

  it { is_expected.to belong_to(:user) }
  it { is_expected.to validate_presence_of(:channel_id) }
  it { is_expected.to validate_numericality_of(:months).only_integer.is_greater_than_or_equal_to(0) }
  it { is_expected.to validate_numericality_of(:streak).only_integer.is_greater_than_or_equal_to(0) }

  it "maps to the channel_tenure table" do
    expect(described_class.table_name).to eq("channel_tenure")
  end
end
