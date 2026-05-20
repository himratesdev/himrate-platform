# frozen_string_literal: true

# TASK-110 FR-013 (v1.2 — Backend CR iter-1 M-2/M-3 fix 2026-05-20):
# Self-hosted whisper.cpp STT via HTTP server accessory `himrate-whisper`.
#
# v1.0: OpenAI Whisper API (superseded — ADR-110 v1.1 SA-2 swap A→B per PO cost=$0 directive).
# v1.1: kamal accessory exec subprocess — ARCHITECTURALLY BROKEN (kamal = deploy CLI, не работает
#       изнутри Rails container; нет SSH-ключей к host, нет топологии). CR M-2 caught.
# v1.2: whisper.cpp native HTTP server (whisper-server) — Rails POSTs WAV multipart к
#       http://himrate-whisper:8080/inference (Docker network DNS, full container name per
#       feedback_kamal_dns_full_names). No SSH, no shared volume (M-3 — multipart upload).
#
# Future upgrade path = TASK-103-b при revenue > $50/мес OR users > 1K (swap к OpenAI API).
#
# IMPORTANT: Call from Sidekiq workers only (long-running inference, NOT в web request cycle).
# Concurrency=1 enforced via dedicated whisper_worker Sidekiq role (deploy.yml), не здесь.

module Multimodal
  class WhisperHttpClient
    READ_TIMEOUT_SEC = 600 # 10min — EC-4 from SRS §3 (CPU realtime small clip)
    CONNECT_TIMEOUT_SEC = 5

    class Error < StandardError; end
    class TimeoutError < Error; end
    class ServerError < Error; end

    def initialize(base_url: default_base_url)
      @base_url = base_url
    end

    # Transcribe WAV audio file → returns Hash { text:, segments:, language:, cost_cents: 0 }.
    # cost_cents always 0 для local whisper.cpp (FR-027 column preserved для TASK-103-b OpenAI swap).
    # @param audio_path [String] absolute path к local WAV file (16kHz mono — Rails ffmpeg pre-converts)
    # @return [Hash] transcript result
    def transcribe(audio_path:)
      raise ArgumentError, "audio_path is required" if audio_path.blank?
      raise Error, "audio_path does not exist: #{audio_path}" unless File.exist?(audio_path)

      response = post_inference(audio_path)
      parse_result(response)
    end

    private

    def default_base_url
      # Docker network DNS — full container name (feedback_kamal_dns_full_names).
      ENV.fetch("WHISPER_SERVER_URL", "http://himrate-whisper:8080")
    end

    def post_inference(audio_path)
      uri = URI("#{@base_url}/inference")

      response = HTTP
                 .timeout(connect: CONNECT_TIMEOUT_SEC, read: READ_TIMEOUT_SEC)
                 .post(uri, form: {
                         file: HTTP::FormData::File.new(audio_path),
                         # BUG-110-C: verbose_json возвращает segments[] + language + words[];
                         # plain "json" отдаёт ТОЛЬКО {text} → segments/language теряются.
                         response_format: "verbose_json"
                       })

      raise ServerError, "whisper-server #{response.status}: #{response.body.to_s.truncate(200)}" unless response.status.to_i == 200

      response.body.to_s
    rescue HTTP::TimeoutError => e
      raise TimeoutError, "whisper-server timeout (#{READ_TIMEOUT_SEC}s): #{e.message}"
    rescue HTTP::ConnectionError => e
      raise ServerError, "whisper-server unreachable at #{@base_url}: #{e.message}"
    end

    def parse_result(json_str)
      data = JSON.parse(json_str)
      {
        text: data["text"].to_s.strip,
        segments: Array(data["segments"]).map do |seg|
          {
            "start_sec" => normalize_ts(seg["t0"] || seg["start"]),
            "end_sec" => normalize_ts(seg["t1"] || seg["end"]),
            "text" => seg["text"].to_s.strip
          }
        end,
        language: data["language"].to_s,
        cost_cents: 0 # v1.x local — always 0; FR-027 column preserved для TASK-103-b OpenAI swap
      }
    rescue JSON::ParserError => e
      raise Error, "Failed to parse whisper-server JSON: #{e.message}"
    end

    # whisper-server segment timestamps: t0/t1 = centiseconds (whisper.cpp convention),
    # start/end = seconds (response_format=json variants). Normalize к float seconds.
    def normalize_ts(value)
      return nil if value.nil?

      f = value.to_f
      # t0/t1 integer centiseconds (e.g. 320 → 3.2s); start/end float seconds.
      value.is_a?(Integer) ? f / 100.0 : f
    end
  end
end
