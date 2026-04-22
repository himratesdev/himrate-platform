# frozen_string_literal: true

# TASK-039 FR-008 (NEW v2.0): GET /api/v1/channels/:id/trends/categories — M12.
# Thin wrapper над Trends::Analysis::CategoryPattern (B3 service).
# Response per SRS §4.2 shape.

module Trends
  module Api
    class CategoriesEndpointService < BaseEndpointService
      def call
        from_ts, to_ts = range
        result = Trends::Analysis::CategoryPattern.call(
          channel: channel, from: from_ts.to_date, to: to_ts.to_date
        )

        {
          data: {
            channel_id: channel.id,
            period: period,
            from: from_ts.iso8601,
            to: to_ts.iso8601,
            **result,
            verdict: build_verdict(result)
          },
          meta: meta
        }
      end

      private

      def build_verdict(result)
        top = result[:top_category]
        return { verdict_en: nil, verdict_ru: nil } if top.nil?

        top_row = result[:categories].find { |c| c[:name] == top }
        delta = top_row&.dig(:vs_baseline_ti_delta)

        if delta&.positive?
          {
            verdict_en: "Best TI in #{top} (+#{delta})",
            verdict_ru: "Лучший TI в #{top} (+#{delta})"
          }
        elsif delta
          {
            verdict_en: "Top category #{top} (#{delta} vs baseline)",
            verdict_ru: "Топ-категория #{top} (#{delta} к baseline)"
          }
        else
          {
            verdict_en: "Top category: #{top}",
            verdict_ru: "Топ-категория: #{top}"
          }
        end
      end
    end
  end
end
