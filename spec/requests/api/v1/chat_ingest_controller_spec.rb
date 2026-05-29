# frozen_string_literal: true

require "rails_helper"
require "sidekiq/testing"

# BUG-251.34 (CR iter2 Should-1): regression coverage for ChatIngestController parallel fix.
# Same Sidekiq 7 strict_args trap as SyncController#push — `messages.map(&:to_unsafe_h)` enqueued
# ActiveSupport::HashWithIndifferentAccess instances into ChatIngestWorker. Fixed inline with
# the sync_controller fix (commit efe38be) via canonical JSON round-trip. Without this spec the
# parallel fix could silently regress (no existing chat_ingest_controller_spec.rb prior to this).
RSpec.describe "Api::V1::ChatIngestController", type: :request do
  let(:user) { create(:user) }
  let(:headers) { auth_headers(user) }

  let(:valid_message) do
    {
      user_id: "12345",
      display_name: "viewer_one",
      text: "Hello chat",
      ts: "2026-05-29T18:00:00.000Z",
      badges: [ "subscriber/12" ]
    }
  end

  around do |example|
    Sidekiq::Testing.fake! { example.run }
  end

  before { ChatIngestWorker.clear }

  describe "POST /api/v1/chat/messages" do
    # TC-1: happy path — 202 Accepted + job enqueued
    it "returns 202 Accepted on valid message batch" do
      post "/api/v1/chat/messages",
           params: { channel_slug: "shroud", messages: [ valid_message ] },
           headers: headers,
           as: :json

      expect(response).to have_http_status(:accepted)
      body = response.parsed_body
      expect(body["accepted"]).to eq(1)
      expect(ChatIngestWorker.jobs.size).to eq(1)
    end

    # TC-2: BUG-251.34 — enqueued messages must be Sidekiq-strict_args-safe.
    # Parallel to SyncController TC-2 in this PR.
    it "enqueues messages as plain Hash with String keys (Sidekiq strict_args compatible) — BUG-251.34" do
      post "/api/v1/chat/messages",
           params: { channel_slug: "shroud", messages: [ valid_message ] },
           headers: headers,
           as: :json

      expect(response).to have_http_status(:accepted)
      payload = ChatIngestWorker.jobs.first["args"].first

      expect(payload).to be_an_instance_of(Hash)
      expect(payload.keys).to all(be_a(String))

      messages = payload["messages"]
      expect(messages).to be_an_instance_of(Array)
      messages.each do |msg|
        expect(msg).to be_an_instance_of(Hash), "expected plain Hash, got #{msg.class}"
        expect(msg.keys).to all(be_a(String)), "expected all String keys, got #{msg.keys.map(&:class).uniq}"
      end
    end

    # TC-3: recursive HWIA absence — same approach as SyncController TC-3.
    it "enqueued payload contains ZERO ActiveSupport::HashWithIndifferentAccess recursively — BUG-251.34" do
      post "/api/v1/chat/messages",
           params: { channel_slug: "shroud", messages: [ valid_message ] },
           headers: headers,
           as: :json

      args = ChatIngestWorker.jobs.first["args"]
      offending_path = find_hwia(args)
      expect(offending_path).to be_nil, "expected no HashWithIndifferentAccess in args tree, found at: #{offending_path}"
    end

    # TC-3b: actual Sidekiq.client_push under strict_args!(true).
    it "passes Sidekiq::Client.push strict_args validation without raising — BUG-251.34" do
      Sidekiq.strict_args!(true)

      post "/api/v1/chat/messages",
           params: { channel_slug: "shroud", messages: [ valid_message ] },
           headers: headers,
           as: :json
      args = ChatIngestWorker.jobs.first["args"]

      expect {
        Sidekiq::Client.push("class" => ChatIngestWorker.to_s, "args" => args, "queue" => "chat")
      }.not_to raise_error
    end

    # TC-4: multi-message batch normalized.
    it "normalizes every message in a multi-message batch" do
      messages = Array.new(5) { |i| valid_message.merge(user_id: "user-#{i}") }

      post "/api/v1/chat/messages",
           params: { channel_slug: "shroud", messages: messages },
           headers: headers,
           as: :json

      expect(response).to have_http_status(:accepted)
      enqueued = ChatIngestWorker.jobs.first["args"].first["messages"]
      expect(enqueued.size).to eq(5)
      expect(enqueued).to all(be_an_instance_of(Hash))
    end

    # TC-5: empty channel_slug → 400 (no worker enqueue).
    it "returns 400 + does NOT enqueue worker when channel_slug is blank" do
      post "/api/v1/chat/messages",
           params: { channel_slug: "", messages: [ valid_message ] },
           headers: headers,
           as: :json

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body["error"]).to eq("invalid_payload")
      expect(ChatIngestWorker.jobs).to be_empty
    end

    # TC-6: empty messages array → 400.
    it "returns 400 when messages array is empty" do
      post "/api/v1/chat/messages",
           params: { channel_slug: "shroud", messages: [] },
           headers: headers,
           as: :json

      expect(response).to have_http_status(:bad_request)
      expect(ChatIngestWorker.jobs).to be_empty
    end

    # TC-7: caps batch at MAX_BATCH_SIZE=100.
    it "caps batch at MAX_BATCH_SIZE (100) — drops the tail" do
      messages = Array.new(105) { |i| valid_message.merge(user_id: "user-#{i}") }

      post "/api/v1/chat/messages",
           params: { channel_slug: "shroud", messages: messages },
           headers: headers,
           as: :json

      expect(response).to have_http_status(:accepted)
      enqueued = ChatIngestWorker.jobs.first["args"].first["messages"]
      expect(enqueued.size).to eq(100)
    end

    # TC-8: unauthenticated → 401.
    it "returns 401 without auth header" do
      post "/api/v1/chat/messages",
           params: { channel_slug: "shroud", messages: [ valid_message ] },
           as: :json

      expect(response).to have_http_status(:unauthorized)
      expect(ChatIngestWorker.jobs).to be_empty
    end
  end

  private

  def auth_headers(user)
    token = Auth::JwtService.encode_access(user.id)
    { "Authorization" => "Bearer #{token}" }
  end

  # BUG-251.34: shared recursive HWIA walker (same logic as sync_controller_spec.rb).
  # Returns path to first offender or nil if tree is clean.
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
