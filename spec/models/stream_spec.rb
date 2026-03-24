# frozen_string_literal: true

require "rails_helper"

RSpec.describe Stream, type: :model do
  describe "associations" do
    it { is_expected.to belong_to(:channel) }
    it { is_expected.to have_many(:signals).class_name("TiSignal").dependent(:destroy) }
    it { is_expected.to have_many(:ccv_snapshots).dependent(:destroy) }
    it { is_expected.to have_many(:chat_messages).dependent(:destroy) }
    it { is_expected.to have_many(:erv_estimates).dependent(:destroy) }
    it { is_expected.to have_many(:per_user_bot_scores).dependent(:destroy) }
    it { is_expected.to have_one(:post_stream_report).dependent(:destroy) }
  end

  describe "validations" do
    it { is_expected.to validate_presence_of(:started_at) }
  end
end
