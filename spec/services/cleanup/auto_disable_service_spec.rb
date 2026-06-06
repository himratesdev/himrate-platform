# frozen_string_literal: true

require "rails_helper"

RSpec.describe Cleanup::AutoDisableService do
  describe ".check_and_disable! (FR-042)" do
    # PR-B2 CR iter-3: `ALERTMANAGER_URL` is now blank by default (observability
    # disabled). Stub the constant to simulate the live env state so the existing
    # assertions exercise the Alertmanager push path rather than direct-Telegram.
    before do
      stub_const("AlertmanagerNotifier::ALERTMANAGER_URL", "http://himrate-alertmanager:9093/api/v2/alerts")
      stub_request(:post, "http://himrate-alertmanager:9093/api/v2/alerts").to_return(status: 200)
    end

    def audit(table, status, run_at:)
      CleanupAuditLog.create!(table_name: table, run_at: run_at, status: status, deleted_count: 0)
    end

    it "disables :cleanup_worker and pushes a critical alert when a table has 3 consecutive error rows" do
      audit("ti_signals", :error, run_at: 3.hours.ago)
      audit("ti_signals", :error, run_at: 2.hours.ago)
      audit("ti_signals", :error, run_at: 1.hour.ago)

      described_class.check_and_disable!

      expect(Flipper.enabled?(:cleanup_worker)).to be false
      expect(a_request(:post, "http://himrate-alertmanager:9093/api/v2/alerts")).to have_been_made.at_least_once
    end

    it "does NOT disable when the last 3 rows are not all errors" do
      audit("ti_signals", :error, run_at: 3.hours.ago)
      audit("ti_signals", :success, run_at: 2.hours.ago)
      audit("ti_signals", :error, run_at: 1.hour.ago)

      described_class.check_and_disable!

      expect(Flipper.enabled?(:cleanup_worker)).to be true
      expect(a_request(:post, "http://himrate-alertmanager:9093/api/v2/alerts")).not_to have_been_made
    end

    it "does NOT disable with fewer than 3 audit rows for a table" do
      audit("tih", :error, run_at: 2.hours.ago)
      audit("tih", :error, run_at: 1.hour.ago)

      described_class.check_and_disable!

      expect(Flipper.enabled?(:cleanup_worker)).to be true
    end

    it "is a no-op when the flag is already disabled (no duplicate alert)" do
      Flipper.disable(:cleanup_worker)
      audit("tih", :error, run_at: 3.hours.ago)
      audit("tih", :error, run_at: 2.hours.ago)
      audit("tih", :error, run_at: 1.hour.ago)

      described_class.check_and_disable!

      expect(a_request(:post, "http://himrate-alertmanager:9093/api/v2/alerts")).not_to have_been_made
    end
  end
end
