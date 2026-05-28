# frozen_string_literal: true

# TASK-113 Δ-1 Wave 1 source #5 handler (FR-016): receives subscription data POST from extension
# (sources #4 GQL replay OR #5 Apollo cache walk). Backend doesn't directly fetch — extension owns
# this path because (a) backend cannot fetch twitch.tv subscriptions without user session cookies,
# (b) Apollo cache walk requires React fiber depth=94 в logged-in browser context (TASK-109 pattern).
#
# Expected payload shape from extension:
#   { source: 4|5,
#     subscriptions: [
#       { channel_twitch_id, channel_login, channel_display_name,
#         tier, cumulative_months, started_at, anniversary_at },
#       ...
#     ],
#     captured_at: ISO-8601
#   }
#
# Upserts channel_tenure rows (existing PVA table from BE-3) + pva_supporter_status (BE-3 categorical).
# Reports per-source state to StateStore.
module PersonalAnalytics
  module Enrollment
    class ExtensionSubsPayloadHandler
      Result = Struct.new(:rows_affected, :error_class, keyword_init: true)

      def self.call(user_id:, payload:)
        new(user_id, payload).call
      end

      def initialize(user_id, payload)
        @user_id = user_id
        @payload = payload
      end

      def call
        # CR iter-1 S5: guard nil source_key BEFORE any StateStore call. Previously raised
        # ArgumentError inside rescue → secondary StateStore.update_source(source_key: nil)
        # raised a second ArgumentError that masked the real "invalid source 99" Sentry trace.
        source_key = source_key_for(@payload["source"])
        raise ArgumentError, "invalid source #{@payload['source']}" unless source_key

        StateStore.update_source(user_id: @user_id, source_key: source_key,
          payload: { status: "in_progress", started_at: Time.current.iso8601 })

        subscriptions = Array.wrap(@payload["subscriptions"])
        rows_count = subscriptions.sum { |sub| upsert_subscription(sub) ? 1 : 0 }

        StateStore.update_source(user_id: @user_id, source_key: source_key,
          payload: { status: "done", completed_at: Time.current.iso8601, rows_affected: rows_count })
        Result.new(rows_affected: rows_count)
      rescue ArgumentError
        # Re-raise — controller's rescue_from renders InvalidSource. Don't write StateStore
        # without resolved source_key (would itself raise; CR iter-1 S5 fix).
        raise
      rescue StandardError => e
        Sentry.capture_exception(e) if defined?(Sentry)
        StateStore.update_source(user_id: @user_id, source_key: source_key,
          payload: { status: "failed", completed_at: Time.current.iso8601,
                     error_class: e.class.name.demodulize })
        Result.new(error_class: e.class.name.demodulize)
      end

      private

      def source_key_for(int)
        case int.to_i
        when 4 then "source_4"
        when 5 then "source_5"
        end
      end

      def upsert_subscription(sub)
        twitch_channel_id = sub["channel_twitch_id"].to_s
        return false if twitch_channel_id.blank?

        # ChannelTenure: twitch_channel_id = STABLE key (BE-3 refine, unique scope user_id);
        # channel_id (uuid) = optional enrichment FK для Channel. Optional resolve Channel canonical
        # entry — если канал не в нашем `channels`, channel_id remains nil (BE-3 client-capture
        # rationale: viewer follows ARBITRARY channels, most не curated).
        channel = Channel.find_by(twitch_id: twitch_channel_id)

        ChannelTenure.find_or_initialize_by(
          user_id: @user_id, twitch_channel_id: twitch_channel_id
        ).tap do |ct|
          ct.assign_attributes(
            channel_id: channel&.id,
            twitch_login: sub["channel_login"],
            sub_tier: parse_tier(sub["tier"]),
            months: sub["cumulative_months"].to_i,
            streak: 0,
            anniversary_at: sub["anniversary_at"].present? ? Date.parse(sub["anniversary_at"]) : nil,
            observed_at: Time.current
          )
          ct.save!
        end
        true
      rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique => e
        Rails.logger.warn("[PVA EnrollmentBackfill] Subscription upsert failed for #{twitch_channel_id}: #{e.message}")
        false
      end

      def parse_tier(tier)
        case tier.to_s
        when "1000", "Prime", "1" then 1
        when "2000", "2" then 2
        when "3000", "3" then 3
        end
      end
    end
  end
end
