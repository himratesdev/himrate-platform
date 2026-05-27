# frozen_string_literal: true

require "rails_helper"

RSpec.describe PvaViewRollup, type: :model do
  subject { build(:pva_view_rollup) }

  it { is_expected.to belong_to(:user) }
  it { is_expected.to validate_presence_of(:twitch_channel_id) }
  it { is_expected.to validate_presence_of(:date) }
  it { is_expected.to validate_numericality_of(:total_seconds).only_integer.is_greater_than_or_equal_to(0) }
  it { is_expected.to validate_numericality_of(:session_count).only_integer.is_greater_than_or_equal_to(0) }
  it { is_expected.to validate_presence_of(:first_seen_at) }
  it { is_expected.to validate_presence_of(:last_seen_at) }
end
