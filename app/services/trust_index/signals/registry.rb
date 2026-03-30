# frozen_string_literal: true

# TASK-028 FR-013: SignalRegistry.
# Loads and iterates all 11 signal classes.
# Each signal wrapped in rescue — error in one does not block others.

module TrustIndex
  module Signals
    class Registry
      SIGNAL_CLASSES = [
        AuthRatio,
        ChatterCcvRatio,
        CcvStepFunction,
        CcvTierClustering,
        ChatBehavior,
        ChannelProtectionScore,
        CrossChannelPresence,
        KnownBotMatch,
        RaidAttribution,
        CcvChatCorrelation,
        AccountProfileScoring
      ].freeze

      def self.all
        SIGNAL_CLASSES.map(&:new)
      end

      def self.find(signal_type)
        signal = all.find { |s| s.signal_type == signal_type }
        raise ArgumentError, "Unknown signal type: #{signal_type}" unless signal

        signal
      end

      # Compute all signals for a given context.
      # Returns Hash{signal_type => BaseSignal::Result}
      # Each signal is isolated — errors don't propagate.
      def self.compute_all(context)
        results = {}

        all.each do |signal|
          results[signal.signal_type] = signal.calculate(context)
        rescue StandardError => e
          Rails.logger.warn(
            "SignalRegistry: #{signal.signal_type} failed — #{e.class}: #{e.message}"
          )
          results[signal.signal_type] = BaseSignal::Result.new(
            value: nil, confidence: 0.0,
            metadata: { error: e.class.name, message: e.message }
          )
        end

        results
      end
    end
  end
end
