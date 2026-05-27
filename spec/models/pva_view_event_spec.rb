# frozen_string_literal: true

require "rails_helper"

RSpec.describe PvaViewEvent, type: :model do
  subject { build(:pva_view_event) }

  it { is_expected.to belong_to(:user) }
  it { is_expected.to belong_to(:channel).optional }
  it { is_expected.to validate_presence_of(:twitch_channel_id) }
  it { is_expected.to validate_length_of(:source_event_hash).is_equal_to(64) }
  it { is_expected.to validate_presence_of(:started_at) }
  it { is_expected.to validate_numericality_of(:seconds).only_integer.is_greater_than_or_equal_to(0) }
  it { is_expected.to validate_inclusion_of(:device).in_array(described_class::DEVICES) }
end
