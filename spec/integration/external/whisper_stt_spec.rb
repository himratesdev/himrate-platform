# frozen_string_literal: true

# External-integration lane (4.3): REAL whisper.cpp STT round-trip. Container healthy ≠ works —
# this is the only proof the /inference path transcribes at all.
#
# ON-DEMAND, NOT NIGHTLY — and that is a decision, not an oversight. It runs wherever WHISPER_URL
# points; integration-external.yml passes one through (repo variable or workflow_dispatch input)
# and warns loudly when it is empty, so a green run never silently implies STT was proven.
# Why no service container in the nightly:
#   * ghcr.io/himratesdev/himrate-whisper is private — an anonymous manifest GET returns 403
#     DENIED, so the pull depends on registry credentials that this repo cannot currently verify.
#   * A service-container pull failure fails the whole job before step 1, which would take the
#     keyless Twitch probes (which need no credentials at all) down with it. Wrong blast radius.
#   * Building from whisper/Dockerfile in-job means a whisper.cpp compile plus a 466 MB model
#     download every night (build-whisper-image.yml budgets 20 min for exactly that) to re-prove
#     an image that same workflow already smoke-tests whenever it changes.
#
# Canonical run — against the live staging accessory (config/deploy.yml pins it to 127.0.0.1:9000
# on the deploy host, so tunnel it):
#   ssh -N -L 9000:127.0.0.1:9000 himrate &
#   WHISPER_URL=http://127.0.0.1:9000 EXTERNAL_INTEGRATION=1 \
#     bundle exec rspec spec/integration/external/whisper_stt_spec.rb --tag external
# Fully local alternative (no server): `docker build -t himrate-whisper ./whisper &&
# docker run -p 8080:8080 himrate-whisper`, then WHISPER_URL=http://localhost:8080.
# NB: the production client resolves WHISPER_SERVER_URL; this spec passes base_url explicitly
# from WHISPER_URL to stay orthogonal.
require "rails_helper"

RSpec.describe "whisper.cpp STT (real inference)", :external, type: :integration do
  before do
    skip "WHISPER_URL not set — whisper /inference NOT verified by this run (see header: tunnel the " \
         "staging accessory, or build + run ./whisper locally)" if ENV["WHISPER_URL"].blank?
  end

  it "transcribes a generated 1s WAV (empty text acceptable for a pure tone)" do
    path = Rails.root.join("tmp/external_stt_probe-#{Process.pid}.wav").to_s
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
