# frozen_string_literal: true

require "rails_helper"

RSpec.describe StreamerRatingRefreshWorker do
  let(:channel) { create(:channel) }

  describe "#perform" do
    context "with completed streams" do
      before do
        5.times do |i|
          stream = create(:stream, channel: channel,
            started_at: (10 - i * 2).days.ago,
            ended_at: (10 - i * 2).days.ago + 3.hours)

          create(:trust_index_history,
            channel: channel, stream: stream,
            trust_index_score: 60.0 + i * 5,
            erv_percent: 60.0 + i * 5,
            ccv: 5000, confidence: 0.85,
            classification: "needs_review",
            cold_start_status: "full",
            signal_breakdown: {},
            calculated_at: stream.ended_at)
        end
      end

      it "creates or updates streamer_rating" do
        expect { described_class.new.perform(channel.id) }
          .to change(StreamerRating, :count).by(1)

        rating = StreamerRating.last
        expect(rating.channel_id).to eq(channel.id)
        expect(rating.rating_score).to be_between(0.0, 100.0)
        expect(rating.streams_count).to eq(5)
        expect(rating.decay_lambda).to eq(0.05)
      end

      it "weights recent streams more heavily and applies Bayesian shrinkage" do
        described_class.new.perform(channel.id)

        rating = StreamerRating.last
        # Most recent stream has TI=80, oldest has TI=60
        # Date-based decay weights recent higher → observed ~74
        # Bayesian shrinkage (5 streams < 7 threshold, prior ~65) pulls down → final ~68
        expect(rating.rating_observed).to be > 70.0 # pre-shrinkage
        expect(rating.rating_score).to be_between(60.0, 80.0) # post-shrinkage
        expect(rating.confidence_level).to eq("medium") # 3-7 streams
      end

      it "updates existing rating on re-run" do
        described_class.new.perform(channel.id)
        first_score = StreamerRating.last.rating_score

        # Add new stream with different TI
        stream = create(:stream, channel: channel, started_at: 1.day.ago, ended_at: 12.hours.ago)
        create(:trust_index_history,
          channel: channel, stream: stream,
          trust_index_score: 90.0, erv_percent: 90.0, ccv: 5000,
          confidence: 0.85, classification: "trusted", cold_start_status: "full",
          signal_breakdown: {}, calculated_at: 12.hours.ago)

        described_class.new.perform(channel.id)

        expect(StreamerRating.count).to eq(1) # Same record, updated
        expect(StreamerRating.last.rating_score).to be > first_score
      end
    end

    context "with 0 streams" do
      it "does not create rating" do
        expect { described_class.new.perform(channel.id) }
          .not_to change(StreamerRating, :count)
      end
    end

    context "with non-existent channel" do
      it "returns without error" do
        expect { described_class.new.perform("non-existent") }.not_to raise_error
      end
    end
  end
end
