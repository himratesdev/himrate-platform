# frozen_string_literal: true

require "rails_helper"

RSpec.describe Coordination::EventsWorker do
  before do
    allow(Flipper).to receive(:enabled?).and_call_original
    allow(Flipper).to receive(:enabled?).with(described_class::FLAG).and_return(true)
    Sidekiq.redis { |r| r.del(described_class::LOCK_KEY) }
  end

  it "does nothing while the flag is off" do
    allow(Flipper).to receive(:enabled?).with(described_class::FLAG).and_return(false)
    expect(Clickhouse::CoordinationQueries).not_to receive(:collect_hour!)

    described_class.new.perform
  end

  it "collects only the missing hours, freshest first, bounded per run" do
    current = Time.current.utc.beginning_of_hour
    already = [current - 1.hour, current - 2.hours]
    allow(Clickhouse::CoordinationQueries).to receive(:collected_hours).and_return(already)
    collected = []
    allow(Clickhouse::CoordinationQueries).to receive(:collect_hour!) { |h| collected << h }

    described_class.new.perform

    expect(collected.size).to eq(described_class::MAX_HOURS_PER_RUN)
    expect(collected).not_to include(*already)
    # the freshest gaps, so a page load sees today's data before an old hole is repaired
    expect(collected.last).to eq(current - 3.hours)
  end

  it "never collects the current hour — it is still filling" do
    allow(Clickhouse::CoordinationQueries).to receive(:collected_hours).and_return([])
    collected = []
    allow(Clickhouse::CoordinationQueries).to receive(:collect_hour!) { |h| collected << h }

    described_class.new.perform

    expect(collected).not_to include(Time.current.utc.beginning_of_hour)
  end

  it "skips while another run holds the lock and releases it afterwards" do
    Sidekiq.redis { |r| r.set(described_class::LOCK_KEY, 1, ex: 60) }
    expect(Clickhouse::CoordinationQueries).not_to receive(:collect_hour!)

    described_class.new.perform
  end
end
