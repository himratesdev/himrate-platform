# frozen_string_literal: true

require "rails_helper"

RSpec.describe Twitch::HermesWebsocket do
  subject(:monitor) { described_class.new }

  describe "#subscribe" do
    it "registers a channel id once (dedup)" do
      monitor.subscribe("123")
      monitor.subscribe("123")
      monitor.subscribe(456) # coerces to string
      expect(monitor.instance_variable_get(:@channel_ids)).to eq(%w[123 456])
    end
  end

  describe "frame handling (#handle_frame)" do
    let(:received) { [] }

    before do
      monitor.on_viewcount = ->(cid, payload) { received << [ cid, payload ] }
      # simulate an established subscription: inner sub id -> channel id
      monitor.instance_variable_set(:@sub_to_channel, { "sub-abc" => "238813810" })
    end

    def notification(pubsub_hash, sub_id: "sub-abc")
      JSON.generate(
        type: "notification",
        notification: {
          subscription: { id: sub_id },
          type: "pubsub",
          pubsub: JSON.generate(pubsub_hash)
        }
      )
    end

    it "extracts viewers + collaboration split from a real viewcount push" do
      frame = notification({
        type: "viewcount", server_time: 1_789_599_891.68,
        viewers: 41_944, collaboration_status: "in_collaboration",
        collaboration_viewers: 54_149, costream_status: "", costream_viewers: 0
      })

      monitor.send(:handle_frame, frame)

      expect(received.size).to eq(1)
      cid, payload = received.first
      expect(cid).to eq("238813810")
      expect(payload["viewers"]).to eq(41_944)
      expect(payload["collaboration_viewers"]).to eq(54_149)
      expect(payload["collaboration_status"]).to eq("in_collaboration")
    end

    it "handles a solo channel (no collaboration)" do
      frame = notification({ type: "viewcount", viewers: 389, collaboration_status: "none", collaboration_viewers: 0 })
      monitor.send(:handle_frame, frame)
      _cid, payload = received.first
      expect(payload["viewers"]).to eq(389)
      expect(payload["collaboration_status"]).to eq("none")
    end

    it "ignores non-viewcount notifications" do
      frame = notification({ type: "stream-up", server_time: 1.0 })
      monitor.send(:handle_frame, frame)
      expect(received).to be_empty
    end

    it "ignores notifications for an unknown subscription id" do
      frame = notification({ type: "viewcount", viewers: 100 }, sub_id: "unknown-sub")
      monitor.send(:handle_frame, frame)
      expect(received).to be_empty
    end

    it "ignores welcome / subscribeResponse control frames" do
      monitor.send(:handle_frame, JSON.generate(type: "welcome", id: "x"))
      monitor.send(:handle_frame, JSON.generate(type: "subscribeResponse", id: "sub-abc"))
      expect(received).to be_empty
    end

    it "does not raise on malformed JSON" do
      expect { monitor.send(:handle_frame, "not json{") }.not_to raise_error
      expect(received).to be_empty
    end
  end

  describe "websocket-driver client contract" do
    it "exposes the anonymous Hermes url with the web Client-ID" do
      expect(monitor.send(:url)).to eq("wss://hermes.twitch.tv/v1?clientId=kimne78kx3ncx6brgo4mv6wki5h1ko")
    end
  end
end
