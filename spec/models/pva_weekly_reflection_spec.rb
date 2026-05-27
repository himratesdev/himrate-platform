# frozen_string_literal: true

require "rails_helper"

RSpec.describe PvaWeeklyReflection, type: :model do
  subject { build(:pva_weekly_reflection) }

  it { is_expected.to belong_to(:user) }
  it { is_expected.to validate_presence_of(:week_start) }
  it { is_expected.to validate_presence_of(:narrative) }
  it { is_expected.to validate_inclusion_of(:reflection_source).in_array(described_class::SOURCES) }
  it { is_expected.to validate_presence_of(:generated_at) }

  it "defaults v1 source to template (LLM = enhancement hook)" do
    expect(described_class::SOURCES).to include("template", "llm")
  end
end
