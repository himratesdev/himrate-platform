# frozen_string_literal: true

# TASK-110 FR-009..013: Async Whisper STT processing для Twitch clip.
# Pipeline: Helix /clips metadata fetch → download clip mp4 (size-capped stream) → ffmpeg extract
# WAV 16kHz mono → whisper-server HTTP multipart POST → persist segments[].
#
# Queue: `whisper_transcripts` — processed by dedicated whisper_worker Sidekiq role concurrency=1
# (deploy.yml), CPU isolation на HOSTKEY 8 vCPU. Sidekiq retry 3× exponential backoff.
class ClipTranscriptWorker
  include Sidekiq::Job
  sidekiq_options queue: :whisper_transcripts, retry: 3

  MAX_CLIP_BYTES = 150 * 1024 * 1024 # S-3: 150MB download cap (OOM guard на 2g container)

  sidekiq_retries_exhausted do |job, ex|
    clip_id = job["args"].first
    transcript = ClipTranscript.find_by(clip_id: clip_id)
    transcript&.update(
      status: "error",
      error_message: "#{ex.class.name}: #{ex.message.truncate(500)}"
    )
    Rails.logger.error("ClipTranscriptWorker: exhausted retries for clip #{clip_id} — #{ex.message}")
  rescue StandardError => e
    Rails.logger.error("ClipTranscriptWorker: dead letter failed — #{e.message}")
  end

  def perform(clip_id)
    transcript = ClipTranscript.find_by(clip_id: clip_id)
    unless transcript
      Rails.logger.warn("ClipTranscriptWorker: clip_transcript #{clip_id} not found")
      return
    end

    return if transcript.cache_hit? # idempotency — другая job уже завершилась

    transcript.update!(status: "processing")
    started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    clip_metadata = Twitch::ClipsClient.new.fetch(clip_id: clip_id)
    transcript.update!(clip_metadata: clip_metadata, broadcaster_id: clip_metadata[:broadcaster_id])

    # Nit-1 (CR iter-2): deterministic clip-id-keyed paths computed BEFORE begin, so ensure
    # cleans up both files даже если download_capped/extract_wav raises mid-way (no leak).
    mp4_path = Rails.root.join("tmp", "clip_#{clip_id}.mp4").to_s
    wav_path = Rails.root.join("tmp", "clip_#{clip_id}.wav").to_s
    begin
      # BUG-110-B: clip mp4 URL via GQL (thumbnail derivation сломан для современных clips).
      mp4_url = Twitch::GqlClient.new.clip_video_url(slug: clip_id)
      raise "clip video URL unavailable (private/deleted/no qualities): #{clip_id}" if mp4_url.blank?

      download_capped(mp4_url, mp4_path)
      extract_wav(mp4_path, wav_path)

      result = Multimodal::WhisperHttpClient.new.transcribe(audio_path: wav_path)
      transcript.update!(
        status: "done",
        text: result[:text], # BUG-110-C: persist full transcript (was parsed но dropped — no column)
        segments: result[:segments],
        whisper_lang: result[:language],
        whisper_cost_cents: result[:cost_cents], # always 0 for local
        cached_at: Time.current
      )
      # N-8 (CR): job timing metric для 5min NFR §11 observability.
      duration = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at
      Rails.logger.info("ClipTranscriptWorker: clip #{clip_id} done в #{duration.round(1)}s (#{result[:segments].size} segments)")
    ensure
      File.delete(wav_path) if File.exist?(wav_path)
      File.delete(mp4_path) if File.exist?(mp4_path) # S-3(b)/Nit-1: cleanup even on mid-pipeline failure
    end
  end

  private

  # S-3(a): stream-to-disk с size cap (OOM guard — Twitch clips могут быть до 100MB+).
  def download_capped(url, dest_path)
    bytes = 0
    File.open(dest_path, "wb") do |file|
      response = HTTP.timeout(30).follow.get(url)
      raise "clip download failed: HTTP #{response.status}" unless response.status.success?

      response.body.each do |chunk|
        bytes += chunk.bytesize
        raise "clip too large (>#{MAX_CLIP_BYTES} bytes)" if bytes > MAX_CLIP_BYTES

        file.write(chunk)
      end
    end
  end

  # S-3(c): capture ffmpeg stderr для diagnostics on failure.
  def extract_wav(mp4_path, wav_path)
    _stdout, stderr, status = Open3.capture3(
      "ffmpeg", "-y", "-i", mp4_path, "-ar", "16000", "-ac", "1", wav_path
    )
    raise "ffmpeg extraction failed: #{stderr.to_s.truncate(500)}" unless status.success?
  end
end
