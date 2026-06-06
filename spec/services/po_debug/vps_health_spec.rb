# frozen_string_literal: true

require "rails_helper"

RSpec.describe PoDebug::VpsHealth do
  describe ".call" do
    context "Prometheus unreachable" do
      before do
        # Net::HTTP open_timeout raises Net::OpenTimeout → service swallows and returns nil per metric.
        stub_request(:get, /himrate-prometheus.*/).to_timeout
      end

      it "returns the structured hash with nil metric values" do
        result = described_class.call

        expect(result).to include(:load, :memory, :swap, :disk, :uptime_hours, :source)
        expect(result[:source]).to eq("prometheus")
        expect(result.dig(:load, :one_min)).to be_nil
        expect(result.dig(:memory, :total_mib)).to be_nil
      end
    end

    context "Prometheus returns valid data" do
      before do
        stub_request(:get, %r{himrate-prometheus.*/api/v1/query})
          .to_return(status: 200, body: {
            status: "success",
            data: { result: [ { value: [ 1717000000, "21.5" ] } ] }
          }.to_json, headers: { "Content-Type" => "application/json" })
      end

      it "parses metric values + computes derived fields" do
        result = described_class.call
        expect(result.dig(:load, :one_min)).to eq(21.5)
      end
    end
  end
end
