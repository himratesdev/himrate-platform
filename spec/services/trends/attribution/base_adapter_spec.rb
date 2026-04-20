# frozen_string_literal: true

require "rails_helper"

RSpec.describe Trends::Attribution::BaseAdapter do
  let(:anomaly) { double("Anomaly", id: "test-id") }

  describe ".call" do
    it "raises NotImplementedError для base class (subclasses must override)" do
      expect { described_class.call(anomaly) }.to raise_error(
        described_class::NotImplementedError, /must implement/
      )
    end

    context "subclass validates attribution Hash contract" do
      let(:broken_adapter) do
        Class.new(described_class) do
          def build_attribution(_anomaly)
            { source: "test", confidence: 2.0, raw_source_data: {} } # confidence out of range
          end
        end
      end

      let(:missing_keys_adapter) do
        Class.new(described_class) do
          def build_attribution(_anomaly)
            { source: "test" } # missing confidence + raw_source_data
          end
        end
      end

      let(:nil_returning_adapter) do
        Class.new(described_class) do
          def build_attribution(_anomaly)
            nil
          end
        end
      end

      it "raises если confidence вне 0..1" do
        expect { broken_adapter.call(anomaly) }.to raise_error(ArgumentError, /confidence/)
      end

      it "raises если missing required keys" do
        expect { missing_keys_adapter.call(anomaly) }.to raise_error(ArgumentError, /missing keys/)
      end

      it "returns nil clean когда adapter не matches" do
        expect(nil_returning_adapter.call(anomaly)).to be_nil
      end
    end
  end
end
