# frozen_string_literal: true

require "rails_helper"

RSpec.describe Trends::LatestTihRefreshWorker, type: :worker do
  it "uses the post_stream queue with retry 3" do
    expect(described_class.get_sidekiq_options["queue"].to_s).to eq("post_stream")
    expect(described_class.get_sidekiq_options["retry"]).to eq(3)
  end

  describe "#perform" do
    # REFRESH ... CONCURRENTLY cannot run inside a transaction (specs use transactional
    # fixtures), so the actual REFRESH SQL is stubbed; the conservation of behaviour
    # (only-when-lock-acquired) is what is asserted here.
    let(:worker) { described_class.new }

    it "REFRESHes the MV CONCURRENTLY when the advisory lock is acquired" do
      allow(worker).to receive(:acquire_lock).and_return(true)
      allow(worker).to receive(:release_lock)
      expect(ActiveRecord::Base.connection).to receive(:execute)
        .with("REFRESH MATERIALIZED VIEW CONCURRENTLY latest_tih_per_stream")

      worker.perform("some-stream-id")
    end

    it "is a no-op (no REFRESH) when the advisory lock is held by another run" do
      allow(worker).to receive(:acquire_lock).and_return(false)
      expect(ActiveRecord::Base.connection).not_to receive(:execute)
        .with("REFRESH MATERIALIZED VIEW CONCURRENTLY latest_tih_per_stream")
      allow(Rails.logger).to receive(:info).and_call_original

      worker.perform("some-stream-id")

      expect(Rails.logger).to have_received(:info).with(/refresh already in progress/)
    end

    it "releases the lock even if the REFRESH raises" do
      allow(worker).to receive(:acquire_lock).and_return(true)
      allow(ActiveRecord::Base.connection).to receive(:execute)
        .with("REFRESH MATERIALIZED VIEW CONCURRENTLY latest_tih_per_stream").and_raise(ActiveRecord::StatementInvalid, "boom")
      expect(worker).to receive(:release_lock)

      expect { worker.perform("some-stream-id") }.to raise_error(ActiveRecord::StatementInvalid)
    end
  end
end
