# frozen_string_literal: true

require "rails_helper"

RSpec.describe HealthScoreRefreshWorker do
  let(:channel) { create(:channel) }

  describe "#perform" do
    context "when :hs_recommendations Flipper is disabled (production default after TASK-201 Phase 1)" do
      before { Flipper.disable(:hs_recommendations) }

      it "returns early without invoking removed Hs::* constants" do
        expect { described_class.new.perform(channel.id) }.not_to raise_error
      end

      it "does not write HealthScore record" do
        expect { described_class.new.perform(channel.id) }
          .not_to change { HealthScore.count }
      end
    end
  end
end
