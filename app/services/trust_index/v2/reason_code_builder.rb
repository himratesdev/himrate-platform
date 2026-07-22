# frozen_string_literal: true

module TrustIndex
  module V2
    # Maps the active L4 band + drivers to the reason-code enum array (SRS FR-009/FR-010, §10A — 12
    # codes). Pure function. Legal-safe: the codes and their §10A i18n strings never say
    # "bot/fraud/fake"; each carries params ({n}, {pct}) the frontend interpolates. Accusatory codes
    # (rows 1-2 / plashka) only when C_hard ∨ C_self ∨ C_inflation (TI v2.1 CCV-shape corroborator, a
    # per-STREAM code that names nobody); a soft deficit alone surfaces the non-accusatory
    # ENGAGEMENT_DEFICIT_UNCORROBORATED (row 6a).
    class ReasonCodeBuilder
      Code = Data.define(:code, :params)
      # Canonical ctx contract (L4 builds this; the class stays duck-typed for isolated tests).
      Ctx = Data.define(:c_hard, :c_self, :c_inflation, :named_count, :named_pct, :self_history_stable,
                        :chatter_quality_high, :cold_start_tier, :stream_count,
                        :raid_window_suppressed_i, :unattributed_surge, :thin_sample)

      # band — BandClassifier::Band (row, sub). ctx — responds to: c_hard, c_self, named_count,
      #   named_pct, self_history_stable, chatter_quality_high, cold_start_tier, stream_count,
      #   raid_window_suppressed_i, unattributed_surge, thin_sample.
      def self.call(band:, ctx:)
        new(band, ctx).call
      end

      def initialize(band, ctx)
        @band = band
        @ctx = ctx
      end

      def call
        (accusatory + positive + amber + grey + cross_cutting).compact
      end

      private

      def code(name, params = {})
        Code.new(code: name, params: params)
      end

      def accusatory
        return [] if @band.row > 2

        [ (@ctx.c_hard ? code("HARD_NAMED_FRACTION", { n: @ctx.named_count, pct: @ctx.named_pct }) : nil),
          (@ctx.c_self ? code("SELF_HISTORY_INFLATION_EVENT") : nil),
          # TI v2.1: C_inflation corroborated the soft deficit (CCV rose without a matching chat-rate
          # rise). Emitted only when it is the corroborator, not when C_hard already named a fraction
          # (avoids a redundant code). Legal-safe, per-STREAM not per-person (names nobody).
          (@ctx.c_inflation && !@ctx.c_hard ? code("INFLATION_EVENT_CORROBORATION") : nil) ]
      end

      def positive
        return [] unless [ 3, 4 ].include?(@band.row)

        [ (@ctx.self_history_stable ? code("SELF_HISTORY_STABLE_CLEAN") : nil),
          (@ctx.chatter_quality_high ? code("CHATTER_QUALITY_HIGH") : nil),
          (@ctx.cold_start_tier == "basic" ? code("PROVISIONAL_BASIC", { n: @ctx.stream_count }) : nil) ]
      end

      def amber
        return [] unless @band.row == 6

        [ code(@band.sub == "6b" ? "CHATTER_QUALITY_LOW" : "ENGAGEMENT_DEFICIT_UNCORROBORATED") ]
      end

      def grey
        return [] unless @band.row == 5

        [ code("COLD_START_INSUFFICIENT", { n: @ctx.stream_count }) ]
      end

      def cross_cutting
        [ (@ctx.raid_window_suppressed_i ? code("RAID_HOST_EMBED_WINDOW") : nil),
          (@ctx.unattributed_surge ? code("UNATTRIBUTED_SURGE") : nil),
          (@ctx.thin_sample ? code("WIDE_INTERVAL_THIN_SAMPLE") : nil) ]
      end
    end
  end
end
