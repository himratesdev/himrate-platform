# frozen_string_literal: true

require "rails_helper"

# Phase 5 (2026-05-31, CR-229 W3 / C1 regression guard): in sidekiq-cron the schedule entry's
# `"queue"` is passed straight into the Sidekiq client push and OVERRIDES the worker class's
# `sidekiq_options queue:`. Worker-side specs alone don't catch a stale `"queue" => "signals"`
# in the cron config — and that exact mismatch defeated the original PR. This spec parses
# config/initializers/sidekiq_cron.rb without booting the initializer and asserts the schedule
# Hash literal directly (cheaper than a full Sidekiq::Cron::Job round-trip).
RSpec.describe "sidekiq_cron schedule (config/initializers/sidekiq_cron.rb)" do
  let(:schedule) { extract_schedule_literal }

  it "live_bot_scoring cron entry enqueues on :bot_scoring (not :signals)" do
    entry = schedule.fetch("live_bot_scoring")
    expect(entry["queue"]).to eq("bot_scoring"),
      "live_bot_scoring cron queue must match LiveBotScoringWorker.sidekiq_options[:queue] = :bot_scoring " \
      "(sidekiq-cron OVERRIDES the worker-class queue at enqueue time). If this drops back to 'signals', " \
      "the cron-enqueued jobs land behind the :signals backlog and PerUserBotScore stops refreshing → " \
      "chat_behavior / known_bot_match / account_profile_scoring signals re-break on live streams."
    expect(entry["class"]).to eq("LiveBotScoringWorker")
  end

  private

  # Parse the initializer file's literal Hash without invoking Sidekiq::Cron::Job.create —
  # avoids any Redis / Sidekiq server side-effects in test env.
  def extract_schedule_literal
    initializer_path = Rails.root.join("config/initializers/sidekiq_cron.rb")
    source = File.read(initializer_path)
    schedule_block = source[/schedule = (\{.*?\n    \})\n\n    schedule\.each/m, 1]
    raise "Could not extract `schedule = { ... }` block from #{initializer_path}" unless schedule_block

    eval(schedule_block) # rubocop:disable Security/Eval — controlled local file, parsed not executed
  end
end
