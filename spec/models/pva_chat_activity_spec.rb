# frozen_string_literal: true

require "rails_helper"

RSpec.describe PvaChatActivity, type: :model do
  subject { build(:pva_chat_activity) }

  it { is_expected.to belong_to(:user) }
  it { is_expected.to validate_presence_of(:twitch_channel_id) }
  it { is_expected.to validate_presence_of(:date) }
  it { is_expected.to validate_numericality_of(:message_count).only_integer.is_greater_than_or_equal_to(0) }
  it { is_expected.to validate_presence_of(:first_seen_at) }
  it { is_expected.to validate_presence_of(:last_seen_at) }
end
