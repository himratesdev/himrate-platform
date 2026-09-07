# frozen_string_literal: true

require "rails_helper"

RSpec.describe Graph::CacheWarmWorker do
  it "writes the freshly built full graph under the key the request path reads" do
    payload = { basis: "chat_presence", nodes: [ { login: "a" } ], edges: [] }
    allow_any_instance_of(Graph::AudienceGraphService).to receive(:build).and_return(payload)

    described_class.new.perform

    expect(Rails.cache.read(Graph::AudienceGraphService::FULL_CACHE_KEY)).to eq(payload)
  end

  it "serves the warmed payload without recomputing on the request path" do
    warmed = { basis: "chat_presence", nodes: [], edges: [] }
    Rails.cache.write(Graph::AudienceGraphService::FULL_CACHE_KEY, warmed)

    expect_any_instance_of(Graph::AudienceGraphService).not_to receive(:build)
    expect(Graph::AudienceGraphService.call).to eq(warmed)
  end
end
