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
    # 2026-06-01 fix — these tables have stream_id FK but were missing cascade. Hit during
    # Phase 2 fuse-streams cleanup (delete_fuse_streams_v4 → FK violation on Stream.destroy).
    it { is_expected.to have_many(:cross_channel_presences).dependent(:destroy) }
    it { is_expected.to have_many(:notifications).dependent(:delete_all) }
  end

  describe "validations" do
    it { is_expected.to validate_presence_of(:started_at) }

    describe "merge_status" do
      it "allows valid statuses" do
        Stream::MERGE_STATUSES.each do |status|
          stream = build(:stream, merge_status: status)
          expect(stream).to be_valid, "Expected '#{status}' to be valid"
        end
      end

      it "rejects invalid status" do
        stream = build(:stream, merge_status: "invalid")
        expect(stream).not_to be_valid
      end

      it "allows nil" do
        stream = build(:stream, merge_status: nil)
        expect(stream).to be_valid
      end
    end
  end
end
