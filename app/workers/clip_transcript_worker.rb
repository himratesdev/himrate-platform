# frozen_string_literal: true

# TASK-110 FR-009..013: Async Whisper STT processing для Twitch clip.
# Pipeline: Helix /clips metadata fetch → download clip mp4 (size-capped stream) → ffmpeg extract
# WAV 16kHz mono → whisper-server HTTP multipart POST → persist segments[].
#
# Queue: `whisper_transcripts` — processed by dedicated whisper_worker Sidekiq role concurrency=1
# (deploy.yml), CPU isolation на Time4VPS 3 cores. Sidekiq retry 3× exponential backoff.
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

    audio_path, mp4_path = download_and_extract_audio(clip_id, clip_metadata)

    begin
      result = Multimodal::WhisperHttpClient.new.transcribe(audio_path: audio_path)
      transcript.update!(
        status: "done",
        segments: result[:segments],
        whisper_lang: result[:language],
        whisper_cost_cents: result[:cost_cents], # always 0 for local
        cached_at: Time.current
      )
      # N-8 (CR): job timing metric для 5min NFR §11 observability.
      duration = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at
      Rails.logger.info("ClipTranscriptWorker: clip #{clip_id} done в #{duration.round(1)}s (#{result[:segments].size} segments)")
    ensure
      File.delete(audio_path) if audio_path && File.exist?(audio_path)
      File.delete(mp4_path) if mp4_path && File.exist?(mp4_path) # S-3(b): mp4 cleanup even on ffmpeg failure
    end
  end

  private

  # N-1 (CR): use validated clip_id (sanitized in controller) для path construction, не raw metadata.
  def download_and_extract_audio(clip_id, clip_metadata)
    mp4_url = derive_mp4_url(clip_metadata[:thumbnail_url])
    tmp_mp4 = Rails.root.join("tmp", "clip_#{clip_id}.mp4").to_s
    tmp_wav = Rails.root.join("tmp", "clip_#{clip_id}.wav").to_s

    download_capped(mp4_url, tmp_mp4)
    extract_wav(tmp_mp4, tmp_wav)

    [ tmp_wav, tmp_mp4 ]
  end

  def derive_mp4_url(thumbnail_url)
    # Twitch clip mp4 derivation from thumbnail_url:
    # https://clips-media-assets2.twitch.tv/.../<clip>-preview-480x272.jpg → .../<clip>.mp4
    thumbnail_url.to_s.sub(/-preview-\d+x\d+\.jpg\z/, ".mp4")
  end

  # S-3(a): stream-to-disk с size cap (OOM guard — Twitch clips могут быть до 100MB+).
  def download_capped(url, dest_path)
    bytes = 0
    File.open(dest_path, "wb") do |file|
      response = HTTP.timeout(30).get(url)
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
