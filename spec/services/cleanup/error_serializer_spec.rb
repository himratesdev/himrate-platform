# frozen_string_literal: true

require "rails_helper"

RSpec.describe Cleanup::ErrorSerializer do
  describe ".sanitize (FR-034)" do
    it "returns a stable error_code (class short name) and a small safe context" do
      result = described_class.sanitize(ArgumentError.new("bad input"), "tih")
      expect(result["error_code"]).to eq("ArgumentError")
      expect(result["error_context"]).to include("table" => "tih", "error_class" => "ArgumentError")
    end

    it "demodulizes namespaced error classes (e.g. ActiveRecord::RecordInvalid → RecordInvalid)" do
      result = described_class.sanitize(ActiveRecord::RecordInvalid.new, "tih")
      expect(result["error_code"]).to eq("RecordInvalid")
    end

    it "redacts UUIDs and emails (no PII leak)" do
      uuid = "11111111-2222-3333-4444-555555555555"
      result = described_class.sanitize(StandardError.new("err for #{uuid}"), "ti_signals")
      expect(described_class.send(:redact, "channel #{uuid} owns a@b.co"))
        .to eq("channel [REDACTED_UUID] owns [REDACTED_EMAIL]")
      expect(result.to_json).not_to include(uuid)
    end

    it "never raises — falls back to {error_code: 'Unknown', ...}" do
      exception = Object.new
      def exception.class
        raise "no class"
      end
      result = described_class.sanitize(exception, "tih")
      expect(result["error_code"]).to eq("Unknown")
      expect(result["error_context"]).to include("table" => "tih")
    end

    it "uses the PG SQLSTATE as error_code for ActiveRecord::StatementInvalid wrapping a PG error" do
      pg_error = instance_double(PG::Result)
      allow(pg_error).to receive(:respond_to?).with(:error_field).and_return(true)
      allow(pg_error).to receive(:error_field).with(PG::Result::PG_DIAG_SQLSTATE).and_return("57014")
      cause = instance_double(PG::QueryCanceled)
      allow(cause).to receive(:respond_to?).with(:result).and_return(true)
      allow(cause).to receive(:result).and_return(pg_error)
      exception = ActiveRecord::StatementInvalid.new("timeout")
      allow(exception).to receive(:cause).and_return(cause)
      allow(exception).to receive(:respond_to?).with(:cause).and_return(true)

      result = described_class.sanitize(exception, "tih")
      expect(result["error_code"]).to eq("57014")
      expect(result["error_context"]["sql_state"]).to eq("57014")
    end
  end
end
