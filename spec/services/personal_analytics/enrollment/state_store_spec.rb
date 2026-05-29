# frozen_string_literal: true

require "rails_helper"

RSpec.describe PersonalAnalytics::Enrollment::StateStore do
  let(:user) { create(:user) }

  before do
    # Stub Redis-write to avoid touching real Sidekiq pool в tests.
    # read_redis_hash removed CR iter-3 N2 (PG-only read path).
    allow(described_class).to receive(:write_redis_hash).and_return(nil)
  end

  describe ".initiate" do
    it "creates новую state row + returns :created" do
      state, status = described_class.initiate(user_id: user.id)
      expect(status).to eq(:created)
      expect(state).to be_persisted
      expect(state.overall_status).to eq("pending")
      expect(state.sources.keys).to match_array(%w[source_1 source_2 source_5])
    end

    it "reuses recent (<30d) state row + returns :reused" do
      described_class.initiate(user_id: user.id)
      PvaEnrollmentBackfillState.find_by(user_id: user.id).update!(
        completed_at: 10.days.ago,
        overall_status: "done"
      )

      state, status = described_class.initiate(user_id: user.id)
      expect(status).to eq(:reused)
    end

    it "force=true overrides skip-logic" do
      described_class.initiate(user_id: user.id)
      PvaEnrollmentBackfillState.find_by(user_id: user.id).update!(
        completed_at: 5.days.ago,
        overall_status: "done"
      )

      _state, status = described_class.initiate(user_id: user.id, force: true)
      expect(status).to eq(:created)
    end
  end

  describe ".update_source" do
    before { described_class.initiate(user_id: user.id) }

    it "updates per-source state cell" do
      described_class.update_source(
        user_id: user.id,
        source_key: "source_1",
        payload: { status: "done", rows_affected: 42, completed_at: Time.current.iso8601 }
      )

      state = PvaEnrollmentBackfillState.find_by(user_id: user.id)
      expect(state.sources["source_1"]["status"]).to eq("done")
      expect(state.sources["source_1"]["rows_affected"]).to eq(42)
    end

    it "rejects invalid source_key" do
      expect {
        described_class.update_source(user_id: user.id, source_key: "source_99", payload: { status: "done" })
      }.to raise_error(ArgumentError)
    end

    it "computes overall_status=done когда all sources done" do
      %w[source_1 source_2 source_5].each do |key|
        described_class.update_source(user_id: user.id, source_key: key,
          payload: { status: "done", completed_at: Time.current.iso8601 })
      end

      state = PvaEnrollmentBackfillState.find_by(user_id: user.id)
      expect(state.overall_status).to eq("done")
      expect(state.completed_at).to be_present
    end

    it "computes overall_status=partial когда mix done+failed" do
      described_class.update_source(user_id: user.id, source_key: "source_1",
        payload: { status: "done", completed_at: Time.current.iso8601 })
      described_class.update_source(user_id: user.id, source_key: "source_2",
        payload: { status: "failed", error_class: "TestError", completed_at: Time.current.iso8601 })

      state = PvaEnrollmentBackfillState.find_by(user_id: user.id)
      expect(state.overall_status).to eq("partial")
      expect(state.failed_sources).to include("source_2")
    end
  end

  describe ".mark_partial_timeout" do
    it "flips stuck in_progress sources to failed" do
      described_class.initiate(user_id: user.id)
      state = PvaEnrollmentBackfillState.find_by(user_id: user.id)
      described_class.update_source(user_id: user.id, source_key: "source_1",
        payload: { status: "in_progress" })

      described_class.mark_partial_timeout(state.reload)
      state.reload
      expect(state.overall_status).to eq("partial_timeout")
      expect(state.sources["source_1"]["status"]).to eq("failed")
      expect(state.sources["source_1"]["error_class"]).to eq("EnrollmentTimeout")
    end
  end

  # BUG-PVA-REDIS-HMSET (2026-05-29) — redis-rb 5.x dropped `mapped_hmset`. The pre-fix
  # call raised `ERR unknown command 'mapped_hmset'`, was swallowed by the rescue, and PG
  # carried the state — functionally non-blocking but generated log noise on every
  # mutation. Modern API: `hset(key, hash)` accepts a single Hash argument. Pin the call
  # shape so the legacy method cannot be silently reintroduced.
  describe ".write_redis_hash (private — call shape)" do
    it "calls conn.hset with the full payload hash (NOT mapped_hmset)" do
      # Un-stub так что real impl runs against the conn double.
      allow(described_class).to receive(:write_redis_hash).and_call_original

      fake_conn = instance_double("Redis")
      expect(fake_conn).to receive(:hset)
        .with("pva:backfill:#{user.id}", instance_of(Hash))
      expect(fake_conn).to receive(:expire)
        .with("pva:backfill:#{user.id}", PersonalAnalytics::Enrollment::StateStore::REDIS_TTL)
      expect(fake_conn).not_to receive(:mapped_hmset)

      # Stub Sidekiq.redis_pool to yield our double.
      pool_double = instance_double("ConnectionPool")
      allow(pool_double).to receive(:with).and_yield(fake_conn)
      allow(Sidekiq).to receive(:redis_pool).and_return(pool_double)

      described_class.initiate(user_id: user.id)
    end
  end
end
