# frozen_string_literal: true

require "rails_helper"

RSpec.describe Ml::FeatureExtractor do
  let(:stream) { create(:stream) }
  let(:extractor) { described_class.new(stream) }

  describe "SCHEMA_VERSION" do
    it "is integer 1 at PR1" do
      expect(described_class::SCHEMA_VERSION).to eq(1)
    end
  end

  describe "#call" do
    it "returns hash with all 25 feature keys (matches StreamFeatureVector::FEATURE_COLUMNS)" do
      result = extractor.call
      expect(result).to be_a(Hash)
      expect(result.keys).to match_array(StreamFeatureVector::FEATURE_COLUMNS)
    end

    it "PR7 group still nil (Maturity yet to land)" do
      # Stub CH calls to avoid live Clickhouse hits в test env
      allow(Clickhouse::ChatQueries).to receive(:chat_feature_aggregates).and_return({})
      allow(Clickhouse::ChatQueries).to receive(:privmsg_counts_for_streams).and_return({})

      result = extractor.call
      pr7_pending_keys = StreamFeatureVector::FEATURE_COLUMNS - %i[
        chatter_to_ccv_ratio peak_to_average_ccv_ratio ccv_coefficient_of_variation ccv_tier_stickiness
        message_entropy unique_message_ratio single_message_chatter_ratio emote_only_ratio
        avg_inter_message_interval_sec timing_regularity_score nlp_contextual_relevance_score
        avg_account_age_days account_creation_date_clustering_gini profile_completeness_ratio engagement_participation_ratio
        follower_growth_cv_90d growth_engagement_correlation follow_unfollow_churn_rate attributed_spike_ratio
        trust_index_30d_std chat_rate_30d_cv viewer_retention_avg_sec
      ]
      pr7_pending_keys.each do |k|
        expect(result[k]).to be_nil, "expected #{k} to be nil pending PR7"
      end
    end

    # PR2: ViewerSignals delegation — extractor returns numeric viewer features when data
    # sufficient. ViewerSignals service has its own per-feature edge-case specs; here we
    # just verify the wire-up.
    it "delegates viewer features to Ml::Features::ViewerSignals (PR2)" do
      allow(Clickhouse::ChatQueries).to receive(:chat_feature_aggregates).and_return({})
      create(:ccv_snapshot, stream: stream, ccv_count: 500, timestamp: 5.minutes.ago)
      create(:ccv_snapshot, stream: stream, ccv_count: 500, timestamp: 4.minutes.ago)
      create(:ccv_snapshot, stream: stream, ccv_count: 500, timestamp: 3.minutes.ago)
      create(:chatters_snapshot, stream: stream, unique_chatters_count: 50, total_messages_count: 0, timestamp: 5.minutes.ago)

      result = extractor.call
      expect(result[:ccv_tier_stickiness]).to eq(1.0) # mean=500 exactly at tier
      expect(result[:peak_to_average_ccv_ratio]).to eq(1.0)
      expect(result[:chatter_to_ccv_ratio]).to be_within(0.001).of(0.1)
    end

    # PR3: ChatSignals delegation — extractor returns numeric chat features when CH aggregates
    # are sufficient. ChatSignals service has its own per-feature edge-case specs.
    it "delegates chat features to Ml::Features::ChatSignals (PR3)" do
      allow(Clickhouse::ChatQueries).to receive(:chat_feature_aggregates).with(stream).and_return(
        total_messages: 1000, unique_messages: 700, unique_chatters: 200,
        messages_with_emotes: 300, single_message_chatters: 60,
        message_entropy_bits: 5.5, mean_inter_msg_sec: 0.6, std_inter_msg_sec: 0.3
      )

      result = extractor.call
      expect(result[:message_entropy]).to eq(5.5)
      expect(result[:unique_message_ratio]).to eq(0.7)
      expect(result[:timing_regularity_score]).to eq(0.5)
      expect(result[:nlp_contextual_relevance_score]).to be_nil # deferred ONNX EPIC
    end

    # PR6: StabilitySignals delegation — extractor returns numeric stability features when
    # TIH + Stream history sufficient (≥5 streams).
    it "delegates stability features to Ml::Features::StabilitySignals (PR6)" do
      allow(Clickhouse::ChatQueries).to receive(:chat_feature_aggregates).and_return({})
      allow(Clickhouse::ChatQueries).to receive(:privmsg_counts_for_streams).and_return({})
      channel = stream.channel
      # Seed 6 TIH rows linked to past streams with varying TI scores (≥ MIN_HISTORY_FOR_VARIANCE).
      6.times do |i|
        past = create(:stream, channel: channel, ended_at: (i + 1).hours.ago)
        TrustIndexHistory.create!(
          channel: channel, stream: past,
          trust_index_score: 75 + i, # 75..80
          calculated_at: (i + 1).hours.ago
        )
      end

      result = extractor.call
      expect(result[:trust_index_30d_std]).to be_a(Numeric)
      expect(result[:trust_index_30d_std]).to be > 0.0
      # viewer_retention_avg_sec always nil — deferred (viewer_session_tracking EPIC)
      expect(result[:viewer_retention_avg_sec]).to be_nil
    end

    # PR5: GrowthSignals delegation — extractor returns numeric growth features when
    # FollowerSnapshot history sufficient (≥7 snapshots in 90d window).
    it "delegates growth features to Ml::Features::GrowthSignals (PR5)" do
      allow(Clickhouse::ChatQueries).to receive(:chat_feature_aggregates).and_return({})
      channel = stream.channel
      # 8 steady-growth snapshots (≥ MIN_SNAPSHOTS_FOR_CV) — clean CV = 0 + 0 churn.
      counts = (0..7).map { |i| 1000 + 10 * i }
      counts.reverse.each_with_index do |c, days_ago|
        create(:follower_snapshot, channel: channel, followers_count: c, timestamp: days_ago.days.ago)
      end

      result = extractor.call
      expect(result[:follower_growth_cv_90d]).to be_within(0.001).of(0.0)
      expect(result[:follow_unfollow_churn_rate]).to eq(0.0)
      expect(result[:attributed_spike_ratio]).to be_nil # no σ-based spike on linear growth
      # growth_engagement_correlation can be nil (no streams = zero variance engagement series)
    end

    # PR4: AccountSignals delegation — extractor returns numeric account features when
    # ChatterProfile cache + FollowerSnapshot data sufficient.
    it "delegates account features to Ml::Features::AccountSignals (PR4)" do
      allow(Clickhouse::ChatQueries).to receive(:chat_feature_aggregates).and_return({})
      channel = stream.channel
      create(:follower_snapshot, channel: channel, followers_count: 1000, timestamp: 1.hour.ago)
      15.times do |i|
        login = "u_#{i}"
        create(:per_user_bot_score, stream: stream, username: login)
        ChatterProfile.create!(
          login: login, twitch_user_id: "tu_#{i}",
          twitch_created_at: (500 + i * 50).days.ago,
          followers_count: 10, follows_count: 5, fetched_at: Time.current
        )
      end

      result = extractor.call
      expect(result[:avg_account_age_days]).to be_a(Numeric)
      expect(result[:profile_completeness_ratio]).to eq(1.0)
      expect(result[:engagement_participation_ratio]).to eq(0.015) # 15/1000
    end
  end

  describe "#metadata" do
    it "schema_version + stream_id + empty insufficient_data_reasons when all features computed" do
      allow_any_instance_of(Ml::Features::ViewerSignals).to receive(:call).and_return(
        chatter_to_ccv_ratio: 0.3, peak_to_average_ccv_ratio: 1.5,
        ccv_coefficient_of_variation: 0.2, ccv_tier_stickiness: 0.8
      )
      allow_any_instance_of(Ml::Features::ViewerSignals).to receive(:insufficient_data_reasons).and_return({})
      # PR3: also stub ChatSignals для all-features-computed scenario
      allow_any_instance_of(Ml::Features::ChatSignals).to receive(:call).and_return(
        message_entropy: 5.0, unique_message_ratio: 0.6,
        single_message_chatter_ratio: 0.3, emote_only_ratio: 0.2,
        avg_inter_message_interval_sec: 0.8, timing_regularity_score: 0.4,
        nlp_contextual_relevance_score: 0.7
      )
      allow_any_instance_of(Ml::Features::ChatSignals).to receive(:insufficient_data_reasons).and_return({})
      # PR4: stub AccountSignals too для all-clean scenario
      allow_any_instance_of(Ml::Features::AccountSignals).to receive(:call).and_return(
        avg_account_age_days: 1500.0, account_creation_date_clustering_gini: 0.3,
        profile_completeness_ratio: 0.8, engagement_participation_ratio: 0.02
      )
      allow_any_instance_of(Ml::Features::AccountSignals).to receive(:insufficient_data_reasons).and_return({})
      # PR5: stub GrowthSignals для all-clean scenario
      allow_any_instance_of(Ml::Features::GrowthSignals).to receive(:call).and_return(
        follower_growth_cv_90d: 0.4, growth_engagement_correlation: 0.6,
        follow_unfollow_churn_rate: 0.1, attributed_spike_ratio: 0.8
      )
      allow_any_instance_of(Ml::Features::GrowthSignals).to receive(:insufficient_data_reasons).and_return({})
      # PR6: stub StabilitySignals для all-clean scenario (viewer_retention остаётся
      # deferred-reason; the test asserts `reasons == {}` — see special-case below).
      allow_any_instance_of(Ml::Features::StabilitySignals).to receive(:call).and_return(
        trust_index_30d_std: 5.0, chat_rate_30d_cv: 0.3, viewer_retention_avg_sec: nil
      )
      allow_any_instance_of(Ml::Features::StabilitySignals).to receive(:insufficient_data_reasons).and_return({})
      extractor.call

      meta = extractor.metadata
      expect(meta[:schema_version]).to eq(described_class::SCHEMA_VERSION)
      expect(meta[:stream_id]).to eq(stream.id)
      expect(meta[:insufficient_data_reasons]).to eq({})
    end

    it "captures per-group insufficient_data_reasons when features go nil" do
      allow(Clickhouse::ChatQueries).to receive(:chat_feature_aggregates).and_return({})
      allow(Clickhouse::ChatQueries).to receive(:privmsg_counts_for_streams).and_return({})
      extractor.call # cold-start stream → viewer/chat/account/growth/stability all report reasons

      meta = extractor.metadata
      expect(meta[:insufficient_data_reasons]).to have_key(:viewer)
      expect(meta[:insufficient_data_reasons]).to have_key(:chat)
      expect(meta[:insufficient_data_reasons]).to have_key(:account)
      expect(meta[:insufficient_data_reasons]).to have_key(:growth)
      expect(meta[:insufficient_data_reasons]).to have_key(:stability)
      expect(meta[:insufficient_data_reasons][:viewer].keys).to include(:chatter_to_ccv_ratio)
      expect(meta[:insufficient_data_reasons][:chat][:nlp_contextual_relevance_score]).to eq("requires_nlp_inference_layer_separate_epic")
      expect(meta[:insufficient_data_reasons][:account].values.uniq).to eq([ "no_chatters" ])
      expect(meta[:insufficient_data_reasons][:growth].values.uniq).to eq([ "insufficient_snapshots" ])
      # Stability: 2 data-dependent reasons + viewer_retention deferred (separate EPIC).
      expect(meta[:insufficient_data_reasons][:stability][:trust_index_30d_std]).to eq("insufficient_trust_index_history")
      expect(meta[:insufficient_data_reasons][:stability][:viewer_retention_avg_sec])
        .to eq("requires_viewer_session_tracking_separate_epic")
    end
  end
end
