# frozen_string_literal: true

module TrustIndex
  module V2
    # The calibration-cell key: category × V-bucket × chat-mode × language.
    #
    # Extracted from ContextBuilder because there are now TWO callers. The engine resolves the cell
    # to COMPUTE the soft bound; the card resolves it to SHOW the reader what "below the norm" is
    # measured against ("in this category, at this size, roughly one viewer in N writes"). Those two
    # must never drift — a displayed baseline that isn't the one the verdict used would be worse than
    # showing nothing.
    module CellKey
      V_BUCKETS = [ [ 1_000, "0-1k" ], [ 5_000, "1k-5k" ], [ 20_000, "5k-20k" ] ].freeze

      module_function

      def v_bucket(v)
        return "0" if v.nil? || v <= 0

        V_BUCKETS.each { |ceil, label| return label if v < ceil }
        "20k+"
      end

      # Chat mode as the calibration corpus segments it: the restriction that most changes who can
      # write. Order matters — a sub-only channel is sub-only even if slow mode is also on.
      def chat_mode(config)
        return "open" unless config
        return "sub-only" if config.subs_only_enabled

        fol = config.followers_only_duration_min
        return "followers-only" if fol && fol >= 0
        return "slow" if config.slow_mode_seconds.to_i.positive?
        return "emote-only" if config.emote_only_enabled

        "open"
      end
    end
  end
end
