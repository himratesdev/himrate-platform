# frozen_string_literal: true

require "rails_helper"

RSpec.describe Trends::QualifyingPercentileSnapshotWorker do
  let(:stream) { create(:stream) }

  describe "#perform" do
    context "when :hs_recommendations Flipper is disabled (production default after TASK-201 Phase 1)" do
      before { Flipper.disable(:hs_recommendations) }

      it "returns early without invoking removed Hs::* constants" do
        expect { described_class.new.perform(stream.id) }.not_to raise_error
      end

      it "does not touch TrustIndexHistory" do
        expect { described_class.new.perform(stream.id) }
          .not_to change { TrustIndexHistory.count }
      end
    end
  end
end
