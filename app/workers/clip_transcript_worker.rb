# frozen_string_literal: true

# TASK-110 FR-009..013: Async Whisper STT processing для Twitch clip.
# Pipeline: Helix /clips metadata fetch → download clip audio (mp4 via thumbnail_url derivation)
# → ffmpeg extract WAV 16kHz mono → whisper.cpp local accessory transcribe → persist segments[].
#
# Queue: `whisper_transcripts` concurrency=1 (CPU isolation, prevents Rails web/job starvation
# на Time4VPS 3 cores). Sidekiq retry 3× exponential backoff (EC-4 timeout, EC-5 queue saturation).
class ClipTranscriptWorker
  include Sidekiq::Job
  sidekiq_options queue: :whisper_transcripts, retry: 3

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

    clip_metadata = fetch_clip_metadata(clip_id)
    transcript.update!(clip_metadata: clip_metadata, broadcaster_id: clip_metadata[:broadcaster_id])

    audio_path = download_and_extract_audio(clip_metadata)

    begin
      result = Multimodal::WhisperLocalClient.new.transcribe(audio_path: audio_path)
      transcript.update!(
        status: "done",
        segments: result[:segments],
        whisper_lang: result[:language],
        whisper_cost_cents: result[:cost_cents], # always 0 for local v1.1
        cached_at: Time.current
      )
    ensure
      File.delete(audio_path) if audio_path && File.exist?(audio_path)
    end
  end

  private

  def fetch_clip_metadata(clip_id)
    Twitch::ClipsClient.new.fetch(clip_id: clip_id)
  rescue Twitch::ClipsClient::ClipNotFoundError => e
    raise # propagate to sidekiq retry/dead-letter handling
  end

  def download_and_extract_audio(clip_metadata)
    # Twitch clip mp4 URL derivation from thumbnail_url (well-known pattern).
    # thumbnail_url: https://clips-media-assets2.twitch.tv/.../<clip>-preview-480x272.jpg
    # mp4 URL: https://clips-media-assets2.twitch.tv/.../<clip>.mp4
    mp4_url = clip_metadata[:thumbnail_url].to_s.sub(/-preview-\d+x\d+\.jpg\z/, ".mp4")

    tmp_mp4 = Rails.root.join("tmp", "clip_#{clip_metadata[:id]}.mp4").to_s
    tmp_wav = Rails.root.join("tmp", "clip_#{clip_metadata[:id]}.wav").to_s

    File.write(tmp_mp4, HTTP.timeout(30).get(mp4_url).body.to_s, mode: "wb")

    # ffmpeg extract WAV 16kHz mono (whisper.cpp requirement)
    system("ffmpeg", "-y", "-i", tmp_mp4, "-ar", "16000", "-ac", "1", tmp_wav,
           out: File::NULL, err: File::NULL) || raise("ffmpeg extraction failed")
    File.delete(tmp_mp4) if File.exist?(tmp_mp4)

    tmp_wav
  end
end
