# frozen_string_literal: true

require "rails_helper"

RSpec.describe Multimodal::WhisperHttpClient do
  let(:client) { described_class.new(base_url: "http://himrate-whisper:8080") }
  let(:audio_path) { Rails.root.join("tmp", "spec_whisper_#{SecureRandom.hex(4)}.wav").to_s }

  before { File.write(audio_path, "RIFF....WAVEfmt fake-wav-bytes") }
  after { File.delete(audio_path) if File.exist?(audio_path) }

  describe "#transcribe" do
    let(:server_response) do
      {
        "text" => "Hello world",
        "language" => "en",
        "segments" => [
          { "t0" => 0, "t1" => 320, "text" => "Hello" },
          { "t0" => 320, "t1" => 600, "text" => "world" }
        ]
      }.to_json
    end

    it "POSTs multipart к /inference and parses JSON segments" do
      stub_request(:post, "http://himrate-whisper:8080/inference")
        .to_return(status: 200, body: server_response)

      result = client.transcribe(audio_path: audio_path)

      expect(result[:text]).to eq("Hello world")
      expect(result[:language]).to eq("en")
      expect(result[:cost_cents]).to eq(0)
      expect(result[:segments].size).to eq(2)
      expect(result[:segments].first).to eq("start_sec" => 0.0, "end_sec" => 3.2, "text" => "Hello")
    end

    it "raises ServerError on non-200" do
      stub_request(:post, "http://himrate-whisper:8080/inference")
        .to_return(status: 500, body: "internal error")

      expect { client.transcribe(audio_path: audio_path) }
        .to raise_error(described_class::ServerError, /500/)
    end

    it "raises ServerError when unreachable" do
      stub_request(:post, "http://himrate-whisper:8080/inference").to_raise(HTTP::ConnectionError)

      expect { client.transcribe(audio_path: audio_path) }
        .to raise_error(described_class::ServerError, /unreachable/)
    end

    it "raises Error when audio file missing" do
      expect { client.transcribe(audio_path: "/nonexistent/path.wav") }
        .to raise_error(described_class::Error, /does not exist/)
    end
  end
end
