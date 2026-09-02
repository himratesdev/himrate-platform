# frozen_string_literal: true

# External-integration lane (4.3): REAL whisper.cpp STT round-trip. Container healthy ≠ works —
# this is the only automated proof the /inference path transcribes at all.
# Local run: `docker build -t himrate-whisper ./whisper && docker run -p 8080:8080 himrate-whisper`
# (docker-compose.yml has no whisper service; ghcr pull needs the org account — build locally),
# then WHISPER_URL=http://localhost:8080. NB: the production client resolves WHISPER_SERVER_URL;
# this spec passes base_url explicitly from WHISPER_URL to stay orthogonal.
require "rails_helper"

RSpec.describe "whisper.cpp STT (real inference)", :external, type: :integration do
  before { skip "WHISPER_URL not set (build + run ./whisper locally)" if ENV["WHISPER_URL"].blank? }

  it "transcribes a generated 1s WAV (empty text acceptable for a pure tone)" do
    path = Rails.root.join("tmp/external_stt_probe.wav").to_s
    write_sine_wav(path, seconds: 1, rate: 16_000, freq: 440)

    result = Multimodal::WhisperHttpClient.new(base_url: ENV["WHISPER_URL"]).transcribe(audio_path: path)
    expect(result).to include(:text, :segments, :language)
    expect(result[:cost_cents]).to eq(0)
  ensure
    FileUtils.rm_f(path)
  end

  # Minimal PCM16 mono WAV writer — no fixture binary in the repo.
  def write_sine_wav(path, seconds:, rate:, freq:)
    n = seconds * rate
    data = Array.new(n) { |i| (Math.sin(2 * Math::PI * freq * i / rate) * 12_000).round }.pack("s<*")
    File.open(path, "wb") do |f|
      f.write("RIFF"); f.write([ 36 + data.bytesize ].pack("V")); f.write("WAVEfmt ")
      f.write([ 16, 1, 1, rate, rate * 2, 2, 16 ].pack("VvvVVvv"))
      f.write("data"); f.write([ data.bytesize ].pack("V")); f.write(data)
    end
  end
end
