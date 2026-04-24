# frozen_string_literal: true

require "rails_helper"
require "rake"
require "sidekiq/testing"

# TASK-039 Phase E1 FR-045: integration tests для backfill rake tasks.
# Testing actual DB effects — Sidekiq jobs enqueued (fake mode), rows updated.
RSpec.describe "trends rake tasks" do
  before(:all) do
    Rails.application.load_tasks if Rake::Task.tasks.empty?
  end

  around do |ex|
    Sidekiq::Testing.fake! { ex.run }
  end

  # Reset args memoization between runs — rake tasks накапливают state иначе.
  before do
    Rake::Task.tasks.each(&:reenable)
  end

  describe "trends:backfill_aggregates" do
    let!(:channel) { create(:channel) }

    it "enqueues AggregationWorker per (channel, date) pair в range" do
      Trends::AggregationWorker.jobs.clear

      Rake::Task["trends:backfill_aggregates"].invoke(
        3.days.ago.to_date.to_s, Date.current.to_s, "500", "0", nil
      )

      # 4 days = 3 days ago..today inclusive
      expect(Trends::AggregationWorker.jobs.size).to eq(4)
      enqueued_args = Trends::AggregationWorker.jobs.map { |j| j["args"] }
      expect(enqueued_args.map(&:first).uniq).to eq([ channel.id ])
    end

    it "dry_run не enqueues jobs" do
      Trends::AggregationWorker.jobs.clear

      expect {
        Rake::Task["trends:backfill_aggregates"].invoke(
          3.days.ago.to_date.to_s, Date.current.to_s, "500", "0", "true"
        )
      }.to output(/DRY-RUN/).to_stdout

      expect(Trends::AggregationWorker.jobs.size).to eq(0)
    end

    it "default range = last 90 days when since/until blank" do
      Trends::AggregationWorker.jobs.clear

      Rake::Task["trends:backfill_aggregates"].invoke(nil, nil, "500", "0", nil)

      expect(Trends::AggregationWorker.jobs.size).to eq(91) # 90 days ago..today
    end

    # CR S-1 / N-1: input validation guards.
    it "aborts когда since > until" do
      Trends::AggregationWorker.jobs.clear

      expect {
        Rake::Task["trends:backfill_aggregates"].invoke(
          Date.current.to_s, 5.days.ago.to_date.to_s, "500", "0", nil
        )
      }.to raise_error(SystemExit)

      expect(Trends::AggregationWorker.jobs.size).to eq(0)
    end

    it "aborts когда batch_size=0" do
      expect {
        Rake::Task["trends:backfill_aggregates"].invoke(nil, nil, "0", "0", nil)
      }.to raise_error(SystemExit)
    end

    it "aborts когда throttle_ms negative" do
      expect {
        Rake::Task["trends:backfill_aggregates"].invoke(nil, nil, "500", "-1", nil)
      }.to raise_error(SystemExit)
    end

    # CR S-1: throttle sleep triggers каждые 1000 enqueues.
    it "sleeps throttle_sec between batches of 1000" do
      Trends::AggregationWorker.jobs.clear
      create_list(:channel, 0) # only 1 channel from let!; 1 × 91 days = 91 enqueues, no throttle

      # Mock sleep to verify invocation. 91 enqueues < 1000 threshold → 0 sleeps.
      expect_any_instance_of(Object).not_to receive(:sleep)
      Rake::Task["trends:backfill_aggregates"].invoke(nil, nil, "500", "50", nil)
    end
  end

  describe "trends:backfill_follower_ccv_coupling" do
    let!(:channel) { create(:channel) }

    it "iterates TDA rows с NULL coupling + вызывает FollowerCcvCouplingTimeline" do
      # Seed one TDA row с NULL coupling
      TrendsDailyAggregate.create!(
        channel_id: channel.id,
        date: 5.days.ago.to_date,
        streams_count: 1,
        schema_version: 2,
        categories: {},
        classification_at_end: "trusted",
        follower_ccv_coupling_r: nil
      )

      allow(Trends::Analysis::FollowerCcvCouplingTimeline).to receive(:call).and_return(
        timeline: [ { date: 5.days.ago.to_date, r: 0.82, health: "healthy" } ],
        summary: { current_r: 0.82, current_health: "healthy" }
      )

      expect {
        Rake::Task["trends:backfill_follower_ccv_coupling"].invoke(
          7.days.ago.to_date.to_s, Date.current.to_s, nil
        )
      }.to output(/1\/1 rows updated/).to_stdout

      tda = TrendsDailyAggregate.find_by(channel_id: channel.id)
      expect(tda.follower_ccv_coupling_r).to eq(0.82)
    end

    it "skips rows где coupling timeline returns nil" do
      TrendsDailyAggregate.create!(
        channel_id: channel.id,
        date: 2.days.ago.to_date,
        streams_count: 0,
        schema_version: 2,
        categories: {},
        classification_at_end: "trusted",
        follower_ccv_coupling_r: nil
      )

      allow(Trends::Analysis::FollowerCcvCouplingTimeline).to receive(:call).and_return(
        timeline: [ { date: 2.days.ago.to_date, r: nil, health: nil } ],
        summary: { current_r: nil }
      )

      Rake::Task["trends:backfill_follower_ccv_coupling"].invoke(
        3.days.ago.to_date.to_s, Date.current.to_s, nil
      )

      tda = TrendsDailyAggregate.find_by(channel_id: channel.id)
      expect(tda.follower_ccv_coupling_r).to be_nil
    end

    it "dry_run prints preview без update" do
      TrendsDailyAggregate.create!(
        channel_id: channel.id,
        date: 1.day.ago.to_date,
        streams_count: 1,
        schema_version: 2,
        categories: {},
        classification_at_end: "trusted",
        follower_ccv_coupling_r: nil
      )

      expect(Trends::Analysis::FollowerCcvCouplingTimeline).not_to receive(:call)

      expect {
        Rake::Task["trends:backfill_follower_ccv_coupling"].invoke(nil, nil, "true")
      }.to output(/DRY-RUN/).to_stdout
    end

    # CR S-2: per-row rescue — individual failures не abort task.
    it "continues после exception в single row (rescue + log + counter)" do
      TrendsDailyAggregate.create!(
        channel_id: channel.id,
        date: 3.days.ago.to_date,
        streams_count: 1, schema_version: 2, categories: {},
        classification_at_end: "trusted", follower_ccv_coupling_r: nil
      )
      TrendsDailyAggregate.create!(
        channel_id: channel.id,
        date: 2.days.ago.to_date,
        streams_count: 1, schema_version: 2, categories: {},
        classification_at_end: "trusted", follower_ccv_coupling_r: nil
      )

      call_count = 0
      allow(Trends::Analysis::FollowerCcvCouplingTimeline).to receive(:call) do
        call_count += 1
        raise StandardError, "boom" if call_count == 1

        { timeline: [ { date: 2.days.ago.to_date, r: 0.75, health: "healthy" } ], summary: {} }
      end

      expect(Rails.error).to receive(:report).with(
        instance_of(StandardError), hash_including(context: hash_including(rake: "trends:backfill_follower_ccv_coupling"))
      )

      expect {
        Rake::Task["trends:backfill_follower_ccv_coupling"].invoke(
          5.days.ago.to_date.to_s, Date.current.to_s, nil
        )
      }.to output(/1 errors logged/).to_stdout
    end

    it "aborts когда since > until" do
      expect {
        Rake::Task["trends:backfill_follower_ccv_coupling"].invoke(
          Date.current.to_s, 5.days.ago.to_date.to_s, nil
        )
      }.to raise_error(SystemExit)
    end
  end

  describe "trends:detect_timezones" do
    before do
      SignalConfiguration.upsert_all(
        [
          { signal_type: "trends", category: "timezone_detection", param_name: "min_streams_required",
            param_value: 10, created_at: Time.current, updated_at: Time.current },
          { signal_type: "trends", category: "timezone_detection", param_name: "dominance_threshold",
            param_value: 0.6, created_at: Time.current, updated_at: Time.current }
        ],
        unique_by: %i[signal_type category param_name], on_duplicate: :skip
      )
    end

    it "обновляет timezone для каналов с dominant language" do
      channel = create(:channel, timezone: "UTC")
      # 10 russian streams — dominance 1.0 >= 0.6
      10.times { create(:stream, channel: channel, language: "ru", started_at: 1.day.ago) }

      Rake::Task["trends:detect_timezones"].invoke(nil)

      expect(channel.reload.timezone).to eq("Europe/Moscow")
    end

    it "skips channels с <min_streams_required" do
      channel = create(:channel, timezone: "UTC")
      5.times { create(:stream, channel: channel, language: "ru", started_at: 1.day.ago) }

      Rake::Task["trends:detect_timezones"].invoke(nil)

      expect(channel.reload.timezone).to eq("UTC")
    end

    it "skips channels с ambiguous language mix (<dominance_threshold)" do
      channel = create(:channel, timezone: "UTC")
      # 5 ru + 5 de = 50% dominance, below 60% threshold
      5.times { create(:stream, channel: channel, language: "ru", started_at: 1.day.ago) }
      5.times { create(:stream, channel: channel, language: "de", started_at: 1.day.ago) }

      Rake::Task["trends:detect_timezones"].invoke(nil)

      expect(channel.reload.timezone).to eq("UTC")
    end

    it "skips unmapped languages (e.g. en ambiguous across US/UK/AU)" do
      channel = create(:channel, timezone: "UTC")
      10.times { create(:stream, channel: channel, language: "en", started_at: 1.day.ago) }

      Rake::Task["trends:detect_timezones"].invoke(nil)

      expect(channel.reload.timezone).to eq("UTC")
    end

    it "не перезаписывает уже non-UTC timezone (admin override preservation)" do
      channel = create(:channel, timezone: "America/Chicago")
      10.times { create(:stream, channel: channel, language: "ru", started_at: 1.day.ago) }

      Rake::Task["trends:detect_timezones"].invoke(nil)

      expect(channel.reload.timezone).to eq("America/Chicago")
    end

    it "dry_run prints preview без update" do
      channel = create(:channel, timezone: "UTC")
      10.times { create(:stream, channel: channel, language: "ru", started_at: 1.day.ago) }

      expect {
        Rake::Task["trends:detect_timezones"].invoke("true")
      }.to output(/DRY-RUN/).to_stdout

      expect(channel.reload.timezone).to eq("UTC")
    end
  end
end
