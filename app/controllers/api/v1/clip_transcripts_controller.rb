# frozen_string_literal: true

# TASK-110 FR-008..018: Twitch Clips on-demand transcripts API.
# Free tier 10/calendar month (Pundit FREE_MONTHLY_LIMIT), Premium unlimited.
# Universal cache discipline (BR-006): 1 Whisper call per unique clip_id, served к all users.

module Api
  module V1
    class ClipTranscriptsController < Api::BaseController
      before_action :authenticate_user!

      # POST /api/v1/clip_transcripts/request — FR-009..011
      # Returns immediate cache hit OR enqueues async Whisper job (returns job_id + estimated_seconds).
      def request_transcript
        clip_id = sanitize_clip_id(params[:clip_id])
        if clip_id.blank?
          skip_authorization
          return render_invalid_clip
        end

        # S-2 (CR): atomic find_or_create — eliminates race на concurrent new clip_id (PK violation).
        # N-2 (CR): broadcaster_id NULL until worker fetches Helix metadata (no "pending" magic string).
        transcript = ClipTranscript.find_or_create_by!(clip_id: clip_id) do |t|
          t.status = "queued"
        end

        # Pundit gate Free 10/мес — FR-014..015. N-10 (CR): single policy instance reused.
        policy = ClipTranscriptPolicy.new(current_user, transcript)
        unless policy.create?
          skip_authorization
          return render_paywall_402
        end
        authorize transcript, :create?, policy_class: ClipTranscriptPolicy

        # Idempotency: record per-user request (UNIQUE (user_id, clip_transcript_id))
        ClipTranscriptRequest.find_or_create_by!(
          user_id: current_user.id,
          clip_transcript_id: clip_id
        ) { |row| row.requested_at = Time.current }

        # Cache hit — return immediately (FR-010, BR-006)
        if transcript.cache_hit?
          return render(json: {
            status: "done",
            transcript: serialize(transcript),
            cache_hit: true,
            remaining: serialize_remaining(policy.remaining_for)
          })
        end

        # Cache miss — enqueue async (FR-011). N-3 (CR): polling = GET /:clip_id (no job_id sentinel).
        ClipTranscriptWorker.perform_async(clip_id)

        render json: {
          status: transcript.status,
          estimated_seconds: 180, # v1.x: 2.5-5 min CPU realtime small clip
          cache_hit: false,
          remaining: serialize_remaining(policy.remaining_for)
        }, status: :accepted
      end

      # GET /api/v1/clip_transcripts/:clip_id — FR-010
      def show
        clip_id = sanitize_clip_id(params[:clip_id])
        if clip_id.blank?
          skip_authorization
          return render_invalid_clip
        end

        transcript = ClipTranscript.find_by(clip_id: clip_id)
        unless transcript
          skip_authorization
          return render(json: { error: "not_found", message: "Transcript not found" }, status: :not_found)
        end

        authorize transcript, :show?, policy_class: ClipTranscriptPolicy

        render json: {
          status: transcript.status,
          transcript: transcript.cache_hit? ? serialize(transcript) : nil,
          cache_hit: transcript.cache_hit?,
          error_message: transcript.error_message,
          remaining: serialize_remaining(ClipTranscriptPolicy.new(current_user, transcript).remaining_for)
        }
      end

      # GET /api/v1/clip_transcripts/remaining — FR-014
      def remaining
        skip_authorization # public to all registered users (Pundit#remaining_for computed inline)
        render json: {
          remaining: serialize_remaining(ClipTranscriptPolicy.new(current_user, nil).remaining_for),
          limit: ClipTranscriptPolicy::FREE_MONTHLY_LIMIT,
          tier: current_user.premium_active? ? "premium" : "free"
        }
      end

      # GET /api/v1/clip_transcripts/by_broadcaster/:broadcaster_id — Premium only (S2.B Архив footer action)
      def by_broadcaster
        broadcaster_id = params[:broadcaster_id].to_s.strip
        authorize ClipTranscript.new, :index?, policy_class: ClipTranscriptPolicy

        transcripts = ClipTranscript.where(broadcaster_id: broadcaster_id).done.order(cached_at: :desc).limit(50)
        render json: { data: transcripts.map { |t| serialize(t) }, count: transcripts.size }
      end

      private

      def sanitize_clip_id(raw)
        return nil if raw.blank?

        # Twitch clip slug — alphanumeric + dashes only, length ≤ 100
        clean = raw.to_s.strip
        return nil unless clean.match?(/\A[A-Za-z0-9_-]{1,100}\z/)

        clean
      end

      def render_invalid_clip
        render json: { error: "invalid_clip_id", message: "clip_id must be valid Twitch clip slug" },
               status: :bad_request
      end

      def render_paywall_402
        render json: {
          error: "limit_reached",
          message: I18n.t("clip_transcripts.errors.free_limit",
                          default: "Free tier limit (10/month) reached"),
          upgrade_url: "https://himrate.com/pricing#premium",
          tier: "free",
          used: ClipTranscriptRequest.month_count_for(current_user),
          limit: ClipTranscriptPolicy::FREE_MONTHLY_LIMIT
        }, status: :payment_required
      end

      # M-4 (CR): Float::INFINITY serializes к JSON null (misleading API contract).
      # Map к explicit "unlimited" string sentinel для premium users. Frontend контракт:
      # remaining = integer (Free) OR "unlimited" (Premium/Business).
      def serialize_remaining(value)
        return "unlimited" if value.is_a?(Float) && value.infinite?

        value
      end

      def serialize(transcript)
        {
          clip_id: transcript.clip_id,
          clip_metadata: transcript.clip_metadata,
          segments: transcript.segments,
          sentiment_scores: transcript.sentiment_scores, # phase-2 nullable
          ai_summary: transcript.ai_summary, # phase-2 nullable
          highlights: transcript.highlights, # phase-2 nullable
          whisper_lang: transcript.whisper_lang,
          cached_at: transcript.cached_at&.iso8601
        }
      end
    end
  end
end
