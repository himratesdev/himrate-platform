# frozen_string_literal: true

# TASK-113 Δ-1 Wave 1 source #2 (FR-016): anonymous GQL ChannelShell batch для avatars + colors
# of channels из user's follow list (source #1 must complete first для max benefit, но runs parallel).
# Uses anonymous Client-ID (kimne78kx3ncx6brgo4mv6wki5h1ko), no OAuth required.
#
# Strategy: query tracked_channels WHERE user_id=? + display_name IS NULL OR avatar_url IS NULL
# → batch into chunks of 35 (Twitch::GqlClient::MAX_BATCH_SIZE) → ChannelShell per login.
# Updates channels table (canonical avatar_url + primary_color_hex + display_name).
#
# Hash: 580ab410bcd0c1ad194224957ae2241e5d252b2c5173d8e0cce9d32d5bb14efe (verified live 2026-05-28).
module PersonalAnalytics
  module Enrollment
    class GqlChannelShellBatchSource
      SOURCE_KEY = "source_2"
      BATCH_SIZE = 35
      CHANNEL_SHELL_HASH = "580ab410bcd0c1ad194224957ae2241e5d252b2c5173d8e0cce9d32d5bb14efe"

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

        logins = collect_target_logins
        return done!(0) if logins.empty?

        rows_count = 0
        logins.each_slice(BATCH_SIZE) do |chunk|
          chunk_result = fetch_batch(chunk)
          rows_count += apply_updates(chunk_result)
        end

        done!(rows_count)
      rescue StandardError => e
        Sentry.capture_exception(e) if defined?(Sentry)
        failed!(e.class.name.demodulize)
      end

      private

      def collect_target_logins
        PvaFollowedChannel
          .where(user_id: @user_id)
          .where.not(twitch_login: [ nil, "" ])
          .pluck(:twitch_login)
          .uniq
      end

      def fetch_batch(logins)
        body = logins.map do |login|
          {
            operationName: "ChannelShell",
            variables: { login: login },
            extensions: { persistedQuery: { version: 1, sha256Hash: CHANNEL_SHELL_HASH } }
          }
        end

        response = HTTP
          .timeout(5)
          .headers("Client-ID" => "kimne78kx3ncx6brgo4mv6wki5h1ko", "Content-Type" => "text/plain")
          .post("https://gql.twitch.tv/gql", body: body.to_json)

        return [] unless response.status.success?

        JSON.parse(response.body.to_s)
      rescue HTTP::TimeoutError, Errno::ECONNREFUSED, JSON::ParserError => e
        Rails.logger.warn("[PVA EnrollmentBackfill] ChannelShell batch failed: #{e.class} #{e.message}")
        []
      end

      def apply_updates(batch_result)
        rows = 0
        Array.wrap(batch_result).each do |item|
          user_data = item.dig("data", "userOrError")
          next unless user_data.is_a?(Hash) && user_data["__typename"] == "User"

          row = PvaFollowedChannel.find_by(
            user_id: @user_id,
            twitch_channel_id: user_data["id"]
          )
          next unless row

          row.update!(
            display_name: user_data["displayName"],
            avatar_url: user_data["profileImageURL"],
            primary_color_hex: user_data["primaryColorHex"]
          )
          rows += 1
        end
        rows
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
