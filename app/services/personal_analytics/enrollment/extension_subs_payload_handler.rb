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
        source_key = source_key_for(@payload["source"])
        raise ArgumentError, "invalid source #{@payload['source']}" unless source_key

        StateStore.update_source(user_id: @user_id, source_key: source_key,
          payload: { status: "in_progress", started_at: Time.current.iso8601 })

        subscriptions = Array.wrap(@payload["subscriptions"])
        rows_count = subscriptions.sum { |sub| upsert_subscription(sub) ? 1 : 0 }

        StateStore.update_source(user_id: @user_id, source_key: source_key,
          payload: { status: "done", completed_at: Time.current.iso8601, rows_affected: rows_count })
        Result.new(rows_affected: rows_count)
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

        # Resolve canonical Channel UUID. Channel model validates twitch_id + login presence.
        # Use SQL find_or_create_by with explicit login fallback (cannot be nil per validation).
        login = sub["channel_login"].presence || "twitch_#{twitch_channel_id}"
        channel = Channel.find_by(twitch_id: twitch_channel_id) ||
                  Channel.create!(twitch_id: twitch_channel_id, login: login,
                    display_name: sub["channel_display_name"])

        ChannelTenure.find_or_initialize_by(user_id: @user_id, channel_id: channel.id).tap do |ct|
          ct.assign_attributes(
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
