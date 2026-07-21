# frozen_string_literal: true

# TASK-032 FR-005: ERV endpoint. CR #1/#5/#7/#8/#10/#11.

module Api
  module V1
    class ErvController < Api::BaseController
      include Channelable

      before_action :authenticate_user_optional!
      before_action :set_channel

      def show
        authorize @channel, :show_erv?

        view = erv_view

        # CR #10: Redis cache 30s
        engine = v2_engine? ? "v2" : "v1"
        payload = Rails.cache.fetch("erv:#{engine}:#{@channel.id}:#{view}", expires_in: 30.seconds) do
          build_erv_payload(view)
        end

        # FR-011: ETag
        etag_value = Digest::MD5.hexdigest(payload.to_json)
        if stale?(etag: etag_value, public: view == :headline)
          render json: { data: payload }
        end
      end

      private

      def erv_view
        return :headline unless current_user

        policy = ChannelPolicy.new(current_user, @channel)
        if policy.premium_access?
          :full
        elsif @channel.live? || PostStreamWindowService.open?(@channel)
          :details
        else
          :headline
        end
      end

      def build_erv_payload(view)
        return build_erv_payload_v2(view) if v2_engine?

        ti = @channel.trust_index_histories.where(engine_version: "v1").order(calculated_at: :desc).first
        return cold_start_payload if ti.nil?

        erv_data = TrustIndex::ErvCalculator.compute(
          ti_score: ti.trust_index_score.to_f,
          ccv: ti.ccv.to_i,
          confidence: ti.confidence.to_f
        )

        # CR #1: i18n-aware label
        payload = {
          erv_percent: erv_data[:erv_percent]&.clamp(0.0, 100.0),
          erv_label: I18n.locale == :ru ? erv_data[:label] : erv_data[:label_en],
          erv_label_color: erv_data[:label_color]
        }

        if view == :details || view == :full
          payload.merge!(
            erv_count: erv_data[:erv_count],
            ccv: ti.ccv.to_i,
            confidence: ti.confidence&.to_f,
            confidence_display: erv_data[:confidence_display]
          )

          cd = erv_data[:confidence_display]
          if cd.is_a?(Hash) && cd[:type] == "range"
            payload[:erv_range_low] = cd[:low]
            payload[:erv_range_high] = cd[:high]
          end
        end

        if view == :full
          payload.merge!(
            bots_estimated: [ ti.ccv.to_i - (erv_data[:erv_count] || 0), 0 ].max,
            auth_percent: latest_auth_ratio,
            historical_erv_percent: historical_erv_7d
          )
        end

        payload
      end

      # PR3b (T1-074, B2): the v2 contract — ERV subtracted count + interval + band + authenticity
      # breakdown. Retired: erv_percent (headline), ErvCalculator rescale, bots_estimated (the
      # subtraction is native — f_hat inside erv_breakdown carries it), auth_percent (dead),
      # confidence_display / erv_range (replaced by erv_interval). erv is the guest-visible
      # headline per access-model v2 (extension = 100% free).
      def build_erv_payload_v2(view)
        ti = @channel.trust_index_histories.where(engine_version: "v2").order(calculated_at: :desc).first
        return cold_start_payload_v2 if ti.nil?

        label_key = TrustIndex::V2::BandClassifier.label_key_for(ti.band_row)
        payload = {
          erv: ti.erv,
          erv_interval: { lo: ti.erv_lo, hi: ti.erv_hi },
          band: { row: ti.band_row, color: ti.band_color, label_key: label_key, sub: ti.band_sub },
          erv_label: I18n.t(label_key, default: nil),
          confirmed_anomaly: { shown: ti.confirmed_anomaly },
          cold_start_tier: ti.cold_start_tier,
          confidence_marker: ti.confidence_marker,
          engine_version: "v2"
        }

        if view == :details || view == :full
          payload.merge!(
            authenticity: ti.authenticity&.to_f,
            ccv: ti.ccv&.to_i,
            erv_breakdown: { v: ti.ccv&.to_i, f_hard: ti.f_hard&.to_f, f_soft: ti.f_soft&.to_f, f_hat: ti.f_hat&.to_f }
          )
        end

        if view == :full
          payload.merge!(
            authenticity_interval: { lo: ti.authenticity_lo&.to_f, hi: ti.authenticity_hi&.to_f },
            historical_authenticity_7d: historical_authenticity_7d
          )
        end

        payload
      end

      def cold_start_payload_v2
        # Surface-audit sweep: erv_label (server-resolved — landing/server-rendered surfaces read it)
        # + explicit-nil authenticity and empty reason_codes so cold-start carries the keys a client
        # written against the labeled band contract may probe (warm payload emits them per-view).
        {
          erv: nil,
          erv_interval: { lo: nil, hi: nil },
          authenticity: nil,
          band: { row: 5, color: "grey", label_key: "band.grey_insufficient", sub: nil },
          erv_label: I18n.t("band.grey_insufficient", default: nil),
          reason_codes: [],
          confirmed_anomaly: { shown: false },
          cold_start_tier: "insufficient",
          confidence_marker: "provisional",
          cold_start: true,
          message: I18n.t("erv.insufficient_data"),
          engine_version: "v2"
        }
      end

      # 7d trend on authenticity (%, scale-free) — averaging raw erv COUNTS across days with
      # different V baselines is meaningless.
      def historical_authenticity_7d
        recent = @channel.trust_index_histories
                         .where(engine_version: "v2")
                         .where("calculated_at >= ?", 7.days.ago)
                         .pluck(:authenticity)
                         .compact

        return nil if recent.empty?

        (recent.sum.to_f / recent.size).round(2)
      end

      def v2_engine?
        Flipper.enabled?(:ti_v2_engine)
      rescue StandardError
        false
      end

      def cold_start_payload
        {
          erv_percent: nil,
          erv_label: nil,
          erv_label_color: nil,
          cold_start: true,
          message: I18n.t("erv.insufficient_data")
        }
      end

      # TASK-251.6: auth_percent intentionally suppressed (nil). ChattersSnapshot.auth_ratio
      # now holds ACTIVE chat-senders / CCV (~0.01–0.08), not the "authenticated/present
      # chatters" share this field implies — surfacing ~3% as "auth_percent" reads as
      # "97% bots" (the misleading, legal-sensitive metric the Auth Ratio signal itself
      # abstains on). Re-enable when a present-chatters source is wired (TASK-251.9).
      def latest_auth_ratio
        nil
      end

      def historical_erv_7d
        recent = @channel.trust_index_histories
                         .where("calculated_at >= ?", 7.days.ago)
                         .pluck(:erv_percent)
                         .compact

        return nil if recent.empty?

        (recent.sum / recent.size).round(2)
      end
    end
  end
end
