# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Health endpoint", type: :request do
  # SRS T-002: GET /health → 200 with DB + Redis OK
  describe "GET /health" do
    it "returns 200 with status ok when DB and Redis are available" do
      allow(ActiveRecord::Base.connection).to receive(:execute).with("SELECT 1").and_return(true)
      redis_mock = instance_double(Redis, ping: "PONG", close: nil)
      allow(Redis).to receive(:new).and_return(redis_mock)

      get "/health"

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body["status"]).to eq("ok")
      expect(body["db"]).to be true
      expect(body["redis"]).to be true
    end
  end

  # SRS T-003: GET /health → 503 when DB is down
  describe "GET /health when DB is down" do
    it "returns 503 with status error" do
      allow(ActiveRecord::Base.connection).to receive(:execute).with("SELECT 1").and_raise(PG::ConnectionBad)
      redis_mock = instance_double(Redis, ping: "PONG", close: nil)
      allow(Redis).to receive(:new).and_return(redis_mock)

      get "/health"

      expect(response).to have_http_status(:service_unavailable)
      body = JSON.parse(response.body)
      expect(body["status"]).to eq("error")
      expect(body["db"]).to be false
    end
  end

  # Additional: Redis down
  describe "GET /health when Redis is down" do
    it "returns 503 with status error" do
      allow(ActiveRecord::Base.connection).to receive(:execute).with("SELECT 1").and_return(true)
      allow(Redis).to receive(:new).and_raise(Redis::CannotConnectError)

      get "/health"

      expect(response).to have_http_status(:service_unavailable)
      body = JSON.parse(response.body)
      expect(body["status"]).to eq("error")
      expect(body["redis"]).to be false
    end
  end
end
