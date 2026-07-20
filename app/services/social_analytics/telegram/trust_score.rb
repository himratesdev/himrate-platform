# frozen_string_literal: true

module SocialAnalytics
  module Telegram
    # Keyless Telegram real-audience score (SA-14 "LQI equivalent"). Computes a 0-100 authenticity from
    # the signals the public preview affords, with the SAME legal-safe band language as the Twitch ERV
    # surface (no «боты»/«накрутка» — neutral anomaly / positive affirmation) and a TRANSPARENT
    # contributing-signals breakdown (our moat vs LabelUp's black-box LQI).
    #
    # Primary signal = «Просматриваемость» (avg views ÷ subscribers): a channel whose posts reach far
    # fewer eyes than its subscriber base has an inflated follower count. Consistency (CV) is a weak
    # secondary modifier. Confidence is capped «provisional» — this is one snapshot of ~20 posts, not a
    # time series; deeper signals (dormant %, join bursts) await the Bot API (Phase-1.5).
    class TrustScore
      # Band table mirrors the deployed ERV 4-band (legal-safe). key: min authenticity.
      BANDS = [
        [ 90, "Аудитория реальная",              "Audience is real",           "green" ],
        [ 80, "Аномалий не замечено",            "No anomalies detected",      "green" ],
        [ 50, "Аномалия онлайна",                "Audience anomaly detected",  "yellow" ],
        [ 0,  "Значительная аномалия онлайна",   "Significant audience anomaly", "red" ]
      ].freeze

      def self.call(metrics)
        new(metrics).call
      end

      def initialize(metrics)
        @m = metrics || {}
      end

      def call
        ratio = @m[:view_sub_ratio]
        return insufficient if ratio.nil? || (@m[:posts_on_page]).to_i < 3

        authenticity = score_from_ratio(ratio)
        authenticity = apply_consistency_penalty(authenticity)
        band = band_for(authenticity)

        {
          score: authenticity,
          band_label: band[1],
          band_label_en: band[2],
          band_color: band[3],
          confidence: confidence,
          signals: contributing_signals(ratio)
        }
      end

      private

      # «Просматриваемость» → authenticity. Healthy TG viewability is 20-50%; below ~8% the audience
      # is far larger on paper than in practice. Piecewise-linear, capped [10, 100].
      def score_from_ratio(ratio)
        v =
          if ratio >= 25 then 92 + [ (ratio - 25) / 5.0, 8 ].min
          elsif ratio >= 15 then 80 + (ratio - 15) * 1.2
          elsif ratio >= 8 then 50 + (ratio - 8) * (30.0 / 7)
          else ratio * (50.0 / 8)
          end
        v.round.clamp(10, 100)
      end

      # Near-zero variance across posts reads as manufactured views — small penalty only (weak signal).
      def apply_consistency_penalty(authenticity)
        cv = @m[:view_cv]
        return authenticity if cv.nil?

        cv < 0.05 ? [ authenticity - 8, 10 ].max : authenticity
      end

      def band_for(authenticity)
        BANDS.find { |min, *| authenticity >= min }
      end

      # One snapshot of ~20 posts → never «full». Mirrors the TI 3-tier cold-start intent.
      def confidence
        posts = @m[:posts_on_page].to_i
        return "insufficient" if posts < 3
        return "provisional" if posts < 10

        "moderate"
      end

      def contributing_signals(ratio)
        sig = [
          { key: "view_sub_ratio", label: "Просматриваемость",
            value: "#{ratio}%", weight: "primary",
            note: ratio >= 15 ? "Просмотры соответствуют базе подписчиков" : "Просмотры заметно ниже базы подписчиков" }
        ]
        if @m[:view_cv]
          sig << { key: "view_consistency", label: "Разброс просмотров",
                   value: @m[:view_cv].to_s, weight: "secondary",
                   note: @m[:view_cv] < 0.05 ? "Необычно ровный разброс" : "Естественный разброс просмотров" }
        end
        sig
      end

      def insufficient
        {
          score: nil, band_label: "Недостаточно данных", band_label_en: "Insufficient data",
          band_color: "grey", confidence: "insufficient", signals: []
        }
      end
    end
  end
end
