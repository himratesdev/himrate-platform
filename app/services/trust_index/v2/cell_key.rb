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

      # The whole key in one call — the only correct way to ask for it.
      #
      # Assembling it by hand is how the read side silently misses: the corpus is keyed by the
      # NORMALISED category slug ("just_chatting"), not by the Twitch game name ("Just Chatting"),
      # so passing the raw name resolves nothing and the card quietly drops the baseline it was
      # supposed to compare against. Caught live 2026-09-09 on the first channel that had one.
      #
      # `category:` lets a caller that already resolved it (ContextBuilder) skip the work.
      def for(stream:, v:, protection_config: nil, category: nil)
        {
          category: category.presence || category_for(stream),
          v_bucket: v_bucket(v),
          chat_mode: chat_mode(protection_config),
          language: language_for(stream)
        }
      end

      def category_for(stream)
        TrustIndex::Signals::CategoryResolver.resolve(stream&.game_name)
      rescue StandardError
        "default"
      end

      # Verbatim, as the engine stores it — the corpus holds "RU", not "ru".
      def language_for(stream)
        stream&.language.presence || "default"
      end

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
