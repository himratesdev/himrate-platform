# frozen_string_literal: true

# TASK-110 FR-013 (v1.1 ChangeRequest 2026-05-20): Self-hosted whisper.cpp STT via Docker accessory
# `himrate-whisper` exec subprocess. Replaces OpenAI Whisper API (ADR-110 v1.1 SA-2 swap A→B per
# PO cost=$0 directive). Future upgrade path = TASK-103-b при revenue > $50/мес OR users > 1K.
#
# Architecture:
# - Sidekiq queue `whisper_transcripts` concurrency=1 (CPU isolation, prevents Rails web/job starvation)
# - Docker accessory `himrate-whisper` (whisper.cpp binary + small model file ~500MB, --cpus="1.5" cap)
# - Audio download from Twitch clip thumbnail_url derived (mp4) → ffmpeg extract WAV → whisper.cpp
# - Sample rate normalization 16kHz mono (whisper.cpp requirement)
#
# IMPORTANT: Call from Sidekiq workers only (long-running subprocess, NOT in web request cycle).

module Multimodal
  class WhisperLocalClient
    HARD_TIMEOUT_SEC = 600 # 10min — EC-4 from SRS §3
    DEFAULT_MODEL = "small"
    ACCESSORY_NAME = "himrate-whisper"

    class Error < StandardError; end
    class TimeoutError < Error; end
    class ModelMissingError < Error; end

    def initialize(model: DEFAULT_MODEL)
      @model = model
    end

    # Transcribe audio file → returns Hash { text:, segments:, language:, cost_cents: 0 }.
    # cost_cents always 0 для local whisper.cpp (FR-027 column preserved для TASK-103-b OpenAI swap).
    # @param audio_path [String] absolute path к local audio file (WAV/MP3, любой ffmpeg-compatible)
    # @return [Hash] transcript result
    def transcribe(audio_path:)
      raise ArgumentError, "audio_path is required" if audio_path.blank?
      raise Error, "audio_path does not exist: #{audio_path}" unless File.exist?(audio_path)

      json = run_whisper_cli(audio_path)
      parse_result(json)
    end

    private

    def run_whisper_cli(audio_path)
      # Kamal accessory exec runs whisper inside himrate-whisper container.
      # Audio file mounted via shared volume (deploy.yml directories: ./tmp:/tmp).
      # Output: JSON to stdout с segments[] + language.
      cmd = [
        "kamal", "accessory", "exec", ACCESSORY_NAME,
        "--",
        "whisper", audio_path,
        "--model", @model,
        "--output-format", "json",
        "--language", "auto"
      ]

      stdout, stderr, status = run_with_timeout(cmd, HARD_TIMEOUT_SEC)

      unless status.success?
        Rails.logger.error("Whisper local failed: #{stderr.to_s.truncate(500)}")
        raise Error, "whisper.cpp exited with status #{status.exitstatus}: #{stderr.to_s.truncate(200)}"
      end

      stdout
    end

    def run_with_timeout(cmd, timeout_sec)
      require "open3"
      stdout = +""
      stderr = +""
      status = nil

      Open3.popen3(*cmd) do |_stdin, stdout_io, stderr_io, wait_thr|
        deadline = Time.current + timeout_sec
        until wait_thr.join(1)
          if Time.current > deadline
            Process.kill("TERM", wait_thr.pid)
            raise TimeoutError, "whisper.cpp exceeded #{timeout_sec}s hard timeout"
          end
        end
        stdout << stdout_io.read
        stderr << stderr_io.read
        status = wait_thr.value
      end

      [ stdout, stderr, status ]
    end

    def parse_result(json_str)
      data = JSON.parse(json_str)
      {
        text: data["text"].to_s.strip,
        segments: Array(data["segments"]).map do |seg|
          {
            "start_sec" => seg["start"]&.to_f,
            "end_sec" => seg["end"]&.to_f,
            "text" => seg["text"].to_s.strip
          }
        end,
        language: data["language"].to_s,
        cost_cents: 0 # v1.1 local — always 0; FR-027 column preserved для TASK-103-b OpenAI swap
      }
    rescue JSON::ParserError => e
      raise Error, "Failed to parse whisper.cpp JSON output: #{e.message}"
    end
  end
end
