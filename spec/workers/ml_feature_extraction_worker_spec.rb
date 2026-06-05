# frozen_string_literal: true

require "rails_helper"

RSpec.describe MlFeatureExtractionWorker do
  let(:stream) { create(:stream) }
  let(:worker) { described_class.new }

  describe "sidekiq_options" do
    it "is enqueued on :post_stream queue (matches StreamerReputationRefreshWorker precedent)" do
      # Sidekiq stores sidekiq_options verbatim — worker declares `queue: :post_stream`
      # (symbol), matching StreamerReputationRefreshWorker which uses the same symbol form.
      # Compare as-is. Note: PR #229 / #246 workers use STRING form
      # (`queue: "stream_lifecycle"`); both forms are valid in Sidekiq, must match worker
      # declaration verbatim in spec.
      expect(described_class.sidekiq_options["queue"]).to eq(:post_stream)
    end

    it "retry: 3 (matches post-stream worker convention)" do
      expect(described_class.sidekiq_options["retry"]).to eq(3)
    end
  end

  before do
    # PR3: ChatSignals queries ClickHouse via `Clickhouse::ChatQueries.chat_feature_aggregates`.
    # CH client isn't available in test env (no docker accessory); default-stub returns empty
    # Hash so ChatSignals sees insufficient data branch. Individual tests overriding this stub
    # для happy-path scenarios.
    allow(Clickhouse::ChatQueries).to receive(:chat_feature_aggregates).and_return({})
  end

  describe "#perform" do
    it "persists 1 StreamFeatureVector row per stream at SCHEMA_VERSION" do
      expect { worker.perform(stream.id) }.to change(StreamFeatureVector, :count).by(1)
      fv = StreamFeatureVector.find_by(stream_id: stream.id, version: Ml::FeatureExtractor::SCHEMA_VERSION)
      expect(fv).to be_present
      expect(fv.calculated_at).to be_within(5.seconds).of(Time.current)
    end

    it "is idempotent: re-running UPDATES the existing row instead of inserting" do
      worker.perform(stream.id)
      first_calc = StreamFeatureVector.find_by(stream_id: stream.id).calculated_at

      sleep 0.1
      expect { worker.perform(stream.id) }.not_to change(StreamFeatureVector, :count)

      fv = StreamFeatureVector.find_by(stream_id: stream.id)
      expect(fv.calculated_at).to be > first_calc
    end

    # CR-249 M2 (iter-2): PR2 made viewer features live → cold-start streams (no snapshots)
    # now correctly populate `insufficient_data_reasons[:viewer]` для всех 4 viewer features.
    # Seed enough source data to exercise the happy-path metadata shape (empty reasons),
    # which matches the test's stated intent (verify jsonb structure + schema_version).
    it "writes extractor_metadata jsonb (happy-path, all viewer+chat+account data sufficient)" do
      # ≥3 CCV snapshots + ≥3 chatters snapshots + ≥30 prior streams с avg_ccv
      # → ViewerSignals returns 4 numeric features.
      3.times { |i| create(:ccv_snapshot, stream: stream, ccv_count: 500, timestamp: (5 - i).minutes.ago) }
      3.times { |i| create(:chatters_snapshot, stream: stream, unique_chatters_count: 50, timestamp: (5 - i).minutes.ago) }
      # CR-iter1 MF-3 (PR-A1, EPIC SCALE ARCHITECTURE Step 2): Stream.avg_ccv column dropped.
      # avg_ccv now sourced from post_stream_reports.ccv_avg via INNER JOIN in ViewerSignals.
      # `stream.update!` no longer accepts avg_ccv → create PSR explicitly for current stream;
      # historical-stream factory transient (spec/factories/streams.rb) auto-builds PSR when
      # avg_ccv: is passed, so the 29.times loop below works unchanged.
      stream.update!(ended_at: Time.current)
      PostStreamReport.find_or_create_by!(stream_id: stream.id) do |psr|
        psr.ccv_avg = 500
        psr.ccv_peak = 500
        psr.duration_ms = ((stream.ended_at - stream.started_at) * 1000).to_i
        psr.generated_at = stream.ended_at
      end
      29.times { |i| create(:stream, channel: stream.channel, ended_at: (i + 1).hours.ago, avg_ccv: 500) }

      # PR3: stub ChatQueries with sufficient aggregates so ChatSignals reports
      # no insufficient reasons either. NLP feature still nil with its deferred-EPIC reason.
      allow(Clickhouse::ChatQueries).to receive(:chat_feature_aggregates).and_return(
        total_messages: 1000, unique_messages: 700, unique_chatters: 200,
        messages_with_emotes: 300, single_message_chatters: 60,
        message_entropy_bits: 5.5, mean_inter_msg_sec: 0.6, std_inter_msg_sec: 0.3
      )

      # PR4: seed ≥10 chatters с ChatterProfile + FollowerSnapshot so AccountSignals
      # returns 4 numeric features without insufficient reasons. PR5: seed ≥14 daily
      # snapshots (covers both MIN_SNAPSHOTS_FOR_CV=7 and MIN_SNAPSHOTS_FOR_CORRELATION=14)
      # so GrowthSignals doesn't report insufficient either.
      15.times do |i|
        login = "acct_chatter_#{i}"
        create(:per_user_bot_score, stream: stream, username: login)
        ChatterProfile.create!(
          login: login, twitch_user_id: "acct_tu_#{i}",
          twitch_created_at: (500 + i * 50).days.ago,
          followers_count: 10, follows_count: 5, fetched_at: Time.current
        )
      end
      # 15 follower snapshots steadily growing — exercises every Growth feature happy path
      # (CV/correlation needs ≥14 daily deltas; volatile distribution drives non-zero results).
      (0..14).each do |i|
        create(:follower_snapshot,
               channel: stream.channel,
               followers_count: 1500 + i * 10 + ((-1)**i) * 3, # mild oscillation → non-zero σ
               timestamp: (14 - i).days.ago)
      end

      # PR6: stub CH privmsg counts so chat_rate_30d_cv can compute over 5+ streams.
      allow(Clickhouse::ChatQueries).to receive(:privmsg_counts_for_streams) do |ids|
        ids.each_with_index.to_h { |id, i| [ id, 5000 + (i * 100) ] }
      end
      # PR6: seed 6+ TIH rows linked to past streams для trust_index_30d_std happy-path.
      # 29 prior streams created above — link 6 of them to TIH rows.
      Stream.where(channel: stream.channel).where.not(id: stream.id).limit(6).each_with_index do |s, i|
        TrustIndexHistory.create!(
          channel: stream.channel, stream: s,
          trust_index_score: 75 + i,
          calculated_at: (i + 1).hours.ago
        )
        s.update!(started_at: s.ended_at - 2.hours) # 2h duration для chat-rate calc
      end

      # PR7: seed channel.twitch_created_at so MaturitySignals can compute account_age.
      stream.channel.update!(twitch_created_at: 500.days.ago)

      worker.perform(stream.id)
      fv = StreamFeatureVector.find_by(stream_id: stream.id)
      expect(fv.extractor_metadata).to include(
        "schema_version" => Ml::FeatureExtractor::SCHEMA_VERSION,
        "stream_id" => stream.id
      )
      # PR6: chat group has only deferred NLP reason; viewer+account fully clean;
      # growth + stability may carry deferred-EPIC or low-σ reasons (expected, not failure).
      reasons = fv.extractor_metadata["insufficient_data_reasons"]
      expect(reasons).not_to have_key("viewer")
      expect(reasons).not_to have_key("account")
      expect(reasons["chat"]).to eq(
        "nlp_contextual_relevance_score" => "requires_nlp_inference_layer_separate_epic"
      )
      # PR6: stability always carries viewer_retention deferred-EPIC reason (by design).
      expect(reasons["stability"]["viewer_retention_avg_sec"])
        .to eq("requires_viewer_session_tracking_separate_epic")
      # PR7: maturity группа НЕ карет insufficient reasons когда twitch_created_at populated.
      expect(reasons).not_to have_key("maturity")
      # PR7: maturity feature values populated.
      expect(fv.account_age_days_capped).to eq(365.0) # 500 days → capped at 365
      expect(fv.total_streams_capped).to be > 0
    end

    # CR-249 N1 fold-in: cold-start stream — 23/25 features nil; 2 maturity features always
    # populate because PR7 MaturitySignals counts streams/hours from PG (the current ended
    # stream itself + its duration). account_age_days_capped REMAINS nil (no twitch_created_at).
    # All other groups (Viewer/Chat/Account/Growth/Stability) return nil under insufficient-data.
    it "cold-start stream — only 2 maturity features populate (no twitch_created_at, no history)" do
      allow(Clickhouse::ChatQueries).to receive(:chat_feature_aggregates).and_return({})
      allow(Clickhouse::ChatQueries).to receive(:privmsg_counts_for_streams).and_return({})

      worker.perform(stream.id)
      fv = StreamFeatureVector.find_by(stream_id: stream.id)
      # PR7: total_streams_capped (= 1, current ended stream) + total_hours_capped (~2h
      # from factory default 3.hours.ago..1.hour.ago) — pure PG counts, no external data.
      expect(fv.total_streams_capped).to eq(1)
      expect(fv.total_hours_capped).to be > 0
      # account_age_days_capped nil — no twitch_created_at yet.
      expect(fv.account_age_days_capped).to be_nil
      # All 23 other features nil — insufficient data on cold-start channel.
      other_nil_keys = StreamFeatureVector::FEATURE_COLUMNS - %i[total_streams_capped total_hours_capped]
      other_nil_keys.each { |k| expect(fv.public_send(k)).to be_nil, "expected #{k} to be nil for cold-start" }
    end

    it "warns + returns gracefully when stream not found (deleted between enqueue and execute)" do
      expect(Rails.logger).to receive(:warn).with(/stream nonexistent not found/)
      expect { worker.perform("nonexistent") }.not_to raise_error
      expect(StreamFeatureVector.count).to eq(0)
    end
  end
end
