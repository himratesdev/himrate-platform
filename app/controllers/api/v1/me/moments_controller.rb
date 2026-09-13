# frozen_string_literal: true

module Api
  module V1
    module Me
      # Screen 07 «Лучшие моменты»: chat-peak moments of a finished stream (real per-minute CH MV
      # data) + the Twitch clips created inside that stream's window (worker-cached — Helix is
      # Sidekiq-only). Viewer-free (any registered user, access-model v2).
      class MomentsController < Api::BaseController
        before_action :authenticate_user!

        STREAMS_LIMIT = 10
        MOMENTS_CACHE_TTL = 12.hours

        # GET /api/v1/me/moments?login=X[&stream_id=]
        def index
          authorize current_user, :index?, policy_class: MomentsPolicy

          channel = Channel.active.find_by("lower(login) = ?", params[:login].to_s.strip.downcase)
          return render json: { error: { code: "CHANNEL_NOT_FOUND" } }, status: :not_found unless channel

          streams = channel.streams.where.not(ended_at: nil).order(started_at: :desc).limit(STREAMS_LIMIT).to_a
          stream = params[:stream_id].present? ? streams.find { |s| s.id == params[:stream_id] } : streams.first
          if stream.nil?
            return render json: {
              data: { channel: channel_block(channel), streams: [], stream: nil, moments: [], clips: { status: "none", items: [] } }
            }
          end

          # Finished stream = immutable chat history → moments cache once computed (~300ms cold).
          moments = Rails.cache.fetch("moments:v1:#{stream.id}", expires_in: MOMENTS_CACHE_TTL) do
            ::Moments::DetectorService.new(stream).call
          end

          render json: {
            data: {
              channel: channel_block(channel),
              streams: streams.map { |s| stream_block(s) },
              stream: stream_block(stream),
              moments: moments,
              clips: clips_block(stream, moments)
            }
          }
        end

        private

        def channel_block(channel)
          { login: channel.login, display_name: channel.display_name }
        end

        def stream_block(stream)
          {
            id: stream.id,
            started_at: stream.started_at&.iso8601,
            ended_at: stream.ended_at&.iso8601,
            game_name: stream.game_name,
            duration_sec: stream.ended_at && stream.started_at ? (stream.ended_at - stream.started_at).to_i : nil
          }
        end

        # Clips come from the worker-populated cache; a cold miss enqueues one fetch (pending marker
        # prevents an enqueue storm) and reports status=pending so the page can refetch.
        def clips_block(stream, moments)
          cached = Rails.cache.read(::Moments::ClipsFetchWorker.cache_key(stream.id))
          if cached.nil?
            unless Rails.cache.exist?(::Moments::ClipsFetchWorker.pending_key(stream.id))
              Rails.cache.write(::Moments::ClipsFetchWorker.pending_key(stream.id), true,
                                expires_in: ::Moments::ClipsFetchWorker::PENDING_TTL)
              ::Moments::ClipsFetchWorker.perform_async(stream.id)
            end
            return { status: "pending", items: [] }
          end

          { status: "ready", items: cached.map { |c| c.merge("moment_offset_sec" => matching_moment(c, moments)) } }
        end

        # How far a clip's vod_offset may sit from a chat-peak window and still be called part of
        # it. Was ±90s, chosen as a guess for an unmeasured misalignment between the VOD timeline
        # and our real clock.
        #
        # Measured 2026-09-13 on 423 clips with a known vod_offset across 94 monitored streams:
        # where a genuine chat peak exists, `stream.started_at + vod_offset` lands ON it — p25, p50
        # and p75 of the offset are all zero, and 75% of clips fall within 20 seconds. There is no
        # systematic delay to absorb. The old ±90 was not compensating for a clock; it was
        # compensating for clips that simply are not at a peak, and it did so by attaching them to
        # a peak up to three minutes away.
        MOMENT_MATCH_TOLERANCE = 30 # seconds — measured spread, not a guess at an offset

        def matching_moment(clip, moments)
          offset = clip["vod_offset"]
          return nil if offset.nil?

          hit = moments.find do |m|
            offset.between?(m[:offset_sec] - MOMENT_MATCH_TOLERANCE,
                            m[:offset_sec] + (m[:duration_sec] || 60) + MOMENT_MATCH_TOLERANCE)
          end
          hit && hit[:offset_sec]
        end
      end
    end
  end
end
