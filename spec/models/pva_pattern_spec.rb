# frozen_string_literal: true

require "rails_helper"

RSpec.describe PvaPattern, type: :model do
  subject { build(:pva_pattern) }

  it { is_expected.to belong_to(:user) }
  it { is_expected.to validate_presence_of(:pattern_type) }
  it { is_expected.to validate_presence_of(:title) }
  it { is_expected.to validate_presence_of(:body) }
  it { is_expected.to validate_presence_of(:computed_at) }
end
