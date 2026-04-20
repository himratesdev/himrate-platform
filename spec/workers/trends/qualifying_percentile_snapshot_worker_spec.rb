# frozen_string_literal: true

require "rails_helper"

RSpec.describe Trends::QualifyingPercentileSnapshotWorker, type: :worker do
  let(:channel) { create(:channel) }
  let(:stream) { create(:stream, channel: channel, game_name: "Just Chatting") }
  let!(:tih) { create(:trust_index_history, channel: channel, stream: stream) }

  describe "#perform" do
    before do
      # Stub CategoryMapper чтобы не depend on HealthScoreSeeds в test env
      # (rails_helper не loads seeds; production категория дополняется через миграцию #9).
      allow(Hs::CategoryMapper).to receive(:map).with("Just Chatting").and_return("just_chatting")
      allow(Hs::ComponentPercentileService).to receive_message_chain(:new, :call)
        .and_return({ engagement: 85.5, ti: 70.0, stability: 60.0, growth: 50.0, consistency: 55.0 })
      allow(Reputation::ComponentPercentileService).to receive_message_chain(:new, :call)
        .and_return({ engagement_consistency: 91.2, growth_pattern: 80.0, follower_quality: 70.0, pattern_history: 75.0 })
    end

    it "updates TIH с snapshot percentiles" do
      described_class.new.perform(stream.id)

      tih.reload
      expect(tih.engagement_percentile_at_end).to eq(85.5)
      expect(tih.engagement_consistency_percentile_at_end).to eq(91.2)
      expect(tih.category_at_end).to eq("just_chatting")
    end

    it "is idempotent — second run overwrites" do
      described_class.new.perform(stream.id)
      first_value = tih.reload.engagement_percentile_at_end

      allow(Hs::ComponentPercentileService).to receive_message_chain(:new, :call)
        .and_return({ engagement: 99.9 })

      described_class.new.perform(stream.id)
      expect(tih.reload.engagement_percentile_at_end).to eq(99.9)
      expect(first_value).not_to eq(99.9)
    end

    it "handles missing percentiles gracefully (nil)" do
      allow(Hs::ComponentPercentileService).to receive_message_chain(:new, :call).and_return(nil)
      allow(Reputation::ComponentPercentileService).to receive_message_chain(:new, :call).and_return(nil)

      described_class.new.perform(stream.id)

      tih.reload
      expect(tih.engagement_percentile_at_end).to be_nil
      expect(tih.engagement_consistency_percentile_at_end).to be_nil
      expect(tih.category_at_end).to eq("just_chatting")
    end

    it "no-ops если stream не найден" do
      expect { described_class.new.perform(SecureRandom.uuid) }.not_to raise_error
    end

    it "no-ops если TIH для stream не найден" do
      orphan_stream = create(:stream, channel: channel)
      expect { described_class.new.perform(orphan_stream.id) }.not_to raise_error
    end
  end
end
