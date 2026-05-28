# frozen_string_literal: true

# TASK-113 Δ-1 Wave 1 source #1 (FR-016): Helix GET /channels/followed backfill для viewer cold-start.
# Reads all followed channels via paginated Helix call (user OAuth scope user:read:follows),
# upserts tracked_channels с followed_at timestamp.
#
# Per ADR v3.0 Variant B: isolated failure semantics (BR-013) — failure не блокирует other sources.
# Reports state через PersonalAnalytics::Enrollment::StateStore.
module PersonalAnalytics
  module Enrollment
    class HelixFollowsSource
      SOURCE_KEY = "source_1"

      Result = Struct.new(:status, :rows_affected, :error_class, keyword_init: true)

      def self.call(user_id)
        new(user_id).call
      end

      def initialize(user_id)
        @user_id = user_id
      end

      def call
        StateStore.update_source(user_id: @user_id, source_key: SOURCE_KEY,
          payload: { status: "in_progress", started_at: Time.current.iso8601 })

        auth_provider = fetch_twitch_provider
        return failed!("MissingAuthProvider") unless auth_provider
        return failed!("MissingFollowsScope") unless scope_granted?(auth_provider)

        client = Twitch::HelixUserFollowsClient.new(auth_provider: auth_provider)
        rows_count = 0

        client.followed_channels_pages.each do |page|
          (page["data"] || []).each do |entry|
            upsert_tracked_channel(entry)
            rows_count += 1
          end
        end

        done!(rows_count)
      rescue Twitch::HelixUserFollowsClient::ScopeError => e
        Sentry.capture_exception(e) if defined?(Sentry)
        failed!("MissingFollowsScope")
      rescue Twitch::HelixUserFollowsClient::AuthError => e
        Sentry.capture_exception(e) if defined?(Sentry)
        failed!("TwitchAuthExpired")
      rescue Twitch::HelixUserFollowsClient::Error => e
        Sentry.capture_exception(e) if defined?(Sentry)
        failed!(e.class.name.demodulize)
      rescue StandardError => e
        Sentry.capture_exception(e) if defined?(Sentry)
        failed!(e.class.name.demodulize)
      end

      private

      def fetch_twitch_provider
        AuthProvider.find_by(user_id: @user_id, provider: "twitch")
      end

      def scope_granted?(auth_provider)
        (auth_provider.scopes || []).include?("user:read:follows")
      end

      def upsert_tracked_channel(entry)
        # entry: { broadcaster_id, broadcaster_login, broadcaster_name, followed_at }
        followed_at = Time.parse(entry["followed_at"])

        # CR iter-1 M3: bounded retry (1) on RecordNotUnique vs unbounded loop. Mirrors pattern
        # corrected in Auth::TwitchOauth#find_or_create_user. After 1 retry, re-raise → Sidekiq
        # retry/dead path takes over (BR-013 isolated failure semantics still hold).
        attempts = 0
        begin
          PvaFollowedChannel.find_or_initialize_by(
            user_id: @user_id,
            twitch_channel_id: entry["broadcaster_id"]
          ).tap do |row|
            row.twitch_login = entry["broadcaster_login"]
            row.display_name = entry["broadcaster_name"]
            row.followed_at ||= followed_at
            row.save!
          end
        rescue ActiveRecord::RecordNotUnique
          attempts += 1
          raise if attempts > 1
          retry
        end
      end

      def done!(rows_count)
        StateStore.update_source(user_id: @user_id, source_key: SOURCE_KEY,
          payload: { status: "done", completed_at: Time.current.iso8601, rows_affected: rows_count })
        Result.new(status: "done", rows_affected: rows_count)
      end

      def failed!(error_class)
        StateStore.update_source(user_id: @user_id, source_key: SOURCE_KEY,
          payload: { status: "failed", completed_at: Time.current.iso8601, error_class: error_class })
        Result.new(status: "failed", error_class: error_class)
      end
    end
  end
end
