# frozen_string_literal: true

require "rails_helper"

RSpec.describe PvaCohort, type: :model do
  subject { build(:pva_cohort) }

  it { is_expected.to belong_to(:user) }
  it { is_expected.to validate_inclusion_of(:cohort_method).in_array(described_class::METHODS) }
  it { is_expected.to validate_presence_of(:computed_at) }

  it "v1 co_watch method (Channel2Vec embedding = enhancement hook)" do
    expect(described_class::METHODS).to eq(%w[co_watch embedding])
  end

  it "maps to the pva_cohort table" do
    expect(described_class.table_name).to eq("pva_cohort")
  end
end
