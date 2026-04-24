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
        3.days.ago.to_date.to_s, Date.current.to_s, "500", nil
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
          3.days.ago.to_date.to_s, Date.current.to_s, "500", "true"
        )
      }.to output(/DRY-RUN/).to_stdout

      expect(Trends::AggregationWorker.jobs.size).to eq(0)
    end

    it "default range = last 90 days when since/until blank" do
      Trends::AggregationWorker.jobs.clear

      Rake::Task["trends:backfill_aggregates"].invoke(nil, nil, "500", nil)

      expect(Trends::AggregationWorker.jobs.size).to eq(91) # 90 days ago..today
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
