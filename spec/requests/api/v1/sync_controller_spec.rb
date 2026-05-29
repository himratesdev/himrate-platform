# frozen_string_literal: true

require "rails_helper"
require "sidekiq/testing"

# BUG-251.34: regression coverage for Sidekiq 7 strict_args at the SyncController boundary.
# Before the fix, `events.map(&:to_unsafe_h)` enqueued ActiveSupport::HashWithIndifferentAccess
# instances, which Sidekiq.strict_args! rejects with ArgumentError — every POST to /sync/events
# returned 500. Extension cold-start (TASK-113 Δ-1 Wave 1) hammered this endpoint and produced a
# continuous 500-storm in production logs. Surfaced by DV PR #223 BUG-251.33 (2026-05-29).
RSpec.describe "Api::V1::SyncController", type: :request do
  let(:user) { create(:user) }
  let(:headers) { auth_headers(user) }

  let(:valid_event) do
    {
      event_type: "stream_view",
      payload: {
        channel: "shroud",
        channel_id: "37402112",
        device: "desktop",
        device_fingerprint: "5e200a13-bfca-4f45-bcc2-fce1cdbcaba0",
        device_label: "Mac · Chrome 148",
        duration_sec: 60,
        login: "shroud",
        watched_at: "2026-05-29T12:25:19.757Z"
      },
      device_fingerprint: "5e200a13-bfca-4f45-bcc2-fce1cdbcaba0",
      synced_at: "2026-05-29T12:25:20.000Z"
    }
  end

  around do |example|
    Sidekiq::Testing.fake! { example.run }
  end

  before { SyncEventBatchWorker.clear }

  describe "POST /api/v1/sync/events" do
    # TC-1: happy path — 202 Accepted + job enqueued
    it "returns 202 Accepted + queued=true on valid event batch" do
      post "/api/v1/sync/events", params: { events: [ valid_event ] }, headers: headers, as: :json

      expect(response).to have_http_status(:accepted)
      body = response.parsed_body
      expect(body["submitted"]).to eq(1)
      expect(body["queued"]).to be(true)
      expect(SyncEventBatchWorker.jobs.size).to eq(1)
    end

    # TC-2: BUG-251.34 regression — enqueued args must be Sidekiq-strict_args-safe.
    # Plain `Hash` (not HashWithIndifferentAccess) and no Symbol keys. Without the fix this
    # endpoint raised ArgumentError before the response was even rendered → 500.
    it "enqueues events as plain Hash with String keys (Sidekiq strict_args compatible) — BUG-251.34" do
      post "/api/v1/sync/events", params: { events: [ valid_event ] }, headers: headers, as: :json

      expect(response).to have_http_status(:accepted)
      job = SyncEventBatchWorker.jobs.first
      enqueued_events = job["args"][1]

      expect(enqueued_events).to be_an(Array)
      enqueued_events.each do |event|
        # The exact class check is what Sidekiq's strict_args does — HashWithIndifferentAccess.is_a?(Hash)
        # is true, but `instance_of?(Hash)` is false. Sidekiq rejects on the strict instance check.
        expect(event).to be_an_instance_of(Hash), "expected plain Hash, got #{event.class}"
        expect(event.keys).to all(be_a(String)), "expected all String keys, got #{event.keys.map(&:class).uniq}"

        # Nested payload must also be plain Hash with String keys (deep_stringify_keys = recursive).
        if event["payload"].is_a?(Hash)
          expect(event["payload"]).to be_an_instance_of(Hash)
          expect(event["payload"].keys).to all(be_a(String))
        end
      end
    end

    # TC-3: BUG-251.34 (CR iter1 Should-4) — recursive HWIA absence is the strict_args contract.
    # The prior assertion (`JSON.parse(args.to_json) == args`) was a false-positive: HWIA implements
    # `==` against plain Hash, so the round-trip passes even if HWIA leaks through. Walking the
    # args tree for any HWIA instance is the only reliable check.
    it "enqueued args contain ZERO ActiveSupport::HashWithIndifferentAccess recursively — BUG-251.34" do
      post "/api/v1/sync/events", params: { events: [ valid_event ] }, headers: headers, as: :json

      args = SyncEventBatchWorker.jobs.first["args"]
      offending_path = find_hwia(args)
      expect(offending_path).to be_nil, "expected no HashWithIndifferentAccess in args tree, found at: #{offending_path}"
    end

    # TC-3b: belt-and-braces — actual Sidekiq.client_push invocation runs verify_json under
    # strict_args. If args contain HWIA the client raises ArgumentError. Even with
    # Sidekiq::Testing.fake!, normalize_item runs strict_args validation before the testing
    # intercept. This is the literal failure mode in production.
    it "passes Sidekiq::Client.push strict_args validation without raising — BUG-251.34" do
      Sidekiq.strict_args!(true) # idempotent; explicit guard against future test-env override

      post "/api/v1/sync/events", params: { events: [ valid_event ] }, headers: headers, as: :json
      args = SyncEventBatchWorker.jobs.first["args"]

      expect {
        Sidekiq::Client.push("class" => SyncEventBatchWorker.to_s, "args" => args, "queue" => "default")
      }.not_to raise_error
    end

    # TC-4: batched payload (multiple events) — all normalized.
    it "normalizes every event in a multi-event batch" do
      events = Array.new(3) { |i| valid_event.merge(device_fingerprint: "dev-#{i}") }

      post "/api/v1/sync/events", params: { events: events }, headers: headers, as: :json

      expect(response).to have_http_status(:accepted)
      enqueued = SyncEventBatchWorker.jobs.first["args"][1]
      expect(enqueued.size).to eq(3)
      expect(enqueued).to all(be_an_instance_of(Hash))
    end

    # TC-5: empty events array → 400 (no worker enqueue).
    it "returns 400 + does NOT enqueue worker when events array is empty" do
      post "/api/v1/sync/events", params: { events: [] }, headers: headers, as: :json

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body["error"]).to eq("invalid_events")
      expect(SyncEventBatchWorker.jobs).to be_empty
    end

    # TC-6: missing events param → 400.
    it "returns 400 when events param is missing entirely" do
      post "/api/v1/sync/events", params: {}, headers: headers, as: :json

      expect(response).to have_http_status(:bad_request)
      expect(SyncEventBatchWorker.jobs).to be_empty
    end

    # TC-7: caps batch size at MAX_BATCH_SIZE=100 (defensive — extension could over-send).
    it "caps batch at MAX_BATCH_SIZE (100) — drops the tail" do
      events = Array.new(105) { |i| valid_event.merge(device_fingerprint: "dev-#{i}") }

      post "/api/v1/sync/events", params: { events: events }, headers: headers, as: :json

      expect(response).to have_http_status(:accepted)
      enqueued = SyncEventBatchWorker.jobs.first["args"][1]
      expect(enqueued.size).to eq(100)
    end

    # TC-8: unauthenticated → 401.
    it "returns 401 without auth header" do
      post "/api/v1/sync/events", params: { events: [ valid_event ] }, as: :json

      expect(response).to have_http_status(:unauthorized)
      expect(SyncEventBatchWorker.jobs).to be_empty
    end
  end

  private

  def auth_headers(user)
    token = Auth::JwtService.encode_access(user.id)
    { "Authorization" => "Bearer #{token}" }
  end

  # BUG-251.34 (CR iter1 Should-4): recursively walks the args tree looking for any
  # ActiveSupport::HashWithIndifferentAccess instance. Returns the path to the offender as a
  # human-readable string (e.g. `[1]["payload"]["channel_id"]`) or nil if none found. Used in
  # TC-3 because HWIA `==` against plain Hash makes JSON round-trip equality a false-positive.
  def find_hwia(obj, path = "")
    return path if obj.is_a?(ActiveSupport::HashWithIndifferentAccess)
    case obj
    when Hash
      obj.each do |k, v|
        r = find_hwia(v, "#{path}[#{k.inspect}]")
        return r if r
      end
    when Array
      obj.each_with_index do |v, i|
        r = find_hwia(v, "#{path}[#{i}]")
        return r if r
      end
    end
    nil
  end
end
