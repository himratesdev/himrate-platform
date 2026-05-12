# frozen_string_literal: true

require "rails_helper"

RSpec.describe Trends::Analysis::BestWorstStreamFinder do
  let(:channel) { create(:channel) }

  before do
    SignalConfiguration.upsert_all([
      { signal_type: "trends", category: "best_worst", param_name: "min_streams_required", param_value: 3, created_at: Time.current, updated_at: Time.current }
    ], unique_by: %i[signal_type category param_name], on_duplicate: :skip)
  end

  # TASK-086 FR-032/BR-002: the finder now reads the latest_tih_per_stream MV
  # (one row per ended stream = that stream's FINAL TIH), refreshed in the real
  # pipeline by Trends::LatestTihRefreshWorker. A plain (non-CONCURRENT) REFRESH
  # is fine inside the transactional fixture.
  def refresh_mv!
    ActiveRecord::Base.connection.execute("REFRESH MATERIALIZED VIEW latest_tih_per_stream")
  end

  it "returns insufficient_data when below min_streams_required" do
    stream = create(:stream, channel: channel)
    create(:trust_index_history, channel: channel, stream: stream, trust_index_score: 80, calculated_at: 1.day.ago)
    refresh_mv!

    result = described_class.call(channel: channel, from: 7.days.ago, to: Time.current)

    expect(result[:insufficient_data]).to be true
    expect(result[:best]).to be_nil
    expect(result[:worst]).to be_nil
  end

  it "returns best and worst by FINAL TI score when enough streams" do
    s1 = create(:stream, channel: channel, game_name: "Just Chatting")
    s2 = create(:stream, channel: channel, game_name: "Fortnite")
    s3 = create(:stream, channel: channel, game_name: "Valorant")

    # An intermediate dip on s2 lower than s2's final score — must be IGNORED now
    # (the MV holds only the final TIH per stream).
    create(:trust_index_history, channel: channel, stream: s2, trust_index_score: 10, calculated_at: 2.5.days.ago)
    create(:trust_index_history, channel: channel, stream: s1, trust_index_score: 92, calculated_at: 3.days.ago)
    create(:trust_index_history, channel: channel, stream: s2, trust_index_score: 50, calculated_at: 2.days.ago)
    create(:trust_index_history, channel: channel, stream: s3, trust_index_score: 75, calculated_at: 1.day.ago)
    refresh_mv!

    result = described_class.call(channel: channel, from: 7.days.ago, to: Time.current)

    expect(result[:insufficient_data]).to be false
    expect(result[:best][:ti]).to eq(92.0)
    expect(result[:best][:game_name]).to eq("Just Chatting")
    expect(result[:worst][:ti]).to eq(50.0)
    expect(result[:worst][:game_name]).to eq("Fortnite")
  end

  it "ignores live streams (not in the MV) and TIH without a stream" do
    s1 = create(:stream, channel: channel)
    s2 = create(:stream, channel: channel)
    s3 = create(:stream, channel: channel)
    live = create(:stream, channel: channel, started_at: 1.hour.ago, ended_at: nil)
    create(:trust_index_history, channel: channel, stream: s1, trust_index_score: 80, calculated_at: 1.day.ago)
    create(:trust_index_history, channel: channel, stream: s2, trust_index_score: 70, calculated_at: 2.days.ago)
    create(:trust_index_history, channel: channel, stream: s3, trust_index_score: 90, calculated_at: 3.days.ago)
    create(:trust_index_history, channel: channel, stream: live, trust_index_score: 99, calculated_at: 30.minutes.ago)
    create(:trust_index_history, channel: channel, stream: nil, trust_index_score: 99, calculated_at: 4.days.ago)
    refresh_mv!

    result = described_class.call(channel: channel, from: 7.days.ago, to: Time.current)

    expect(result[:best][:ti]).to eq(90.0)
  end

  it "reads from the latest_tih_per_stream MV — rows not yet refreshed are not seen" do
    s1 = create(:stream, channel: channel)
    s2 = create(:stream, channel: channel)
    s3 = create(:stream, channel: channel)
    [ s1, s2, s3 ].each_with_index { |s, i| create(:trust_index_history, channel: channel, stream: s, trust_index_score: 60 + i, calculated_at: (i + 1).days.ago) }
    # NOT refreshed → MV empty → insufficient

    expect(described_class.call(channel: channel, from: 7.days.ago, to: Time.current)[:insufficient_data]).to be true

    refresh_mv!
    expect(described_class.call(channel: channel, from: 7.days.ago, to: Time.current)[:insufficient_data]).to be false
  end
end
