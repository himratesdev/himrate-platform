# frozen_string_literal: true

# TASK-027: Per-User Bot Scoring Engine.
# Weighted sum scoring per BFT §04 Scoring-ML-Infrastructure.
# Input: username + stream context (IRC tags, chat patterns, known bot data, GQL profile).
# Output: { score: 0.0-1.0, classification: String, components: Hash, confidence: Float }
#
# Signal weights from BFT:
#   Definitive (1.0): 2+ bot databases, 100+ channels/day
#   Very High (0.95): 1 bot database
#   High (0.60-0.70): CV timing, entropy, profileViewCount=0, followers=0, createdAt<7d
#   Medium (0.30-0.40): createdAt<30d, follows=0, follows>1000, 0 custom emotes, description=null
#   Low (0.10-0.15): bannerImageURL=null, videos=0, lastBroadcast=null
#   Anti-bot (negative): mod/VIP whitelist, subscriber, returning-chatter, prediction/poll, hype train

module BotDetection
  class Scorer
    # BFT thresholds. Upper bound exclusive (except confirmed_bot).
    CLASSIFICATION_THRESHOLDS = [
      ["human",         0.0, 0.2],
      ["low_suspicion", 0.2, 0.5],
      ["suspicious",    0.5, 0.75],
      ["probable_bot",  0.75, 0.95],
      ["confirmed_bot", 0.95, Float::INFINITY]
    ].freeze

    WHITELIST_TYPES = %w[mod vip partner affiliate staff].freeze

    Result = Data.define(:score, :classification, :components, :confidence)

    def initialize(known_bot_service: nil)
      @known_bot_service = known_bot_service || KnownBotService.new
    end

    # Main scoring method.
    # stream_context = {
    #   irc_tags: { subscriber_status:, user_type:, returning_chatter:, vip:, badge_info:, bits_used: },
    #   chat_stats: { message_count:, cv_timing:, entropy:, custom_emote_ratio: },
    #   known_bot: { bot:, confidence:, sources: },
    #   cross_channel_count: Integer,
    #   profile: { created_at:, profile_view_count:, followers_count:, follows_count:,
    #              description:, banner_image_url:, videos_count:, last_broadcast_at: } (optional)
    # }
    def score(username, stream_context)
      components = {}
      name = username.to_s.downcase.strip

      # Step 1: Whitelist check (FR-003)
      if whitelisted?(stream_context[:irc_tags])
        return build_result(0.0, components.merge(whitelist: { value: true, weight: 0.0, contribution: -1.0 }), 1.0)
      end

      # Step 2: Definitive signals (FR-002)
      definitive = check_definitive(stream_context, components)
      return build_result(1.0, components, 1.0) if definitive

      # Step 3: Positive signals (weighted sum)
      positive_score = 0.0
      positive_score += score_known_bot(stream_context[:known_bot], components)
      positive_score += score_chat_behavior(stream_context[:chat_stats], components)
      positive_score += score_profile(stream_context[:profile], components)

      # Step 4: Anti-bot adjustments (FR-004)
      anti_bot_adjustment = score_anti_bot(stream_context[:irc_tags], components)

      # Step 5: Clamp (FR-003 from BRD — BR-003)
      raw_score = positive_score + anti_bot_adjustment
      final_score = raw_score.clamp(0.0, 1.0)

      # Step 6: Confidence
      confidence = calculate_confidence(stream_context, components)

      build_result(final_score, components, confidence)
    end

    private

    # === Step 1: Whitelist ===

    def whitelisted?(irc_tags)
      return false unless irc_tags

      user_type = irc_tags[:user_type].to_s.downcase
      return true if WHITELIST_TYPES.include?(user_type)

      vip = irc_tags[:vip]
      return true if vip == true || vip == "1"

      false
    end

    # === Step 2: Definitive ===

    def check_definitive(context, components)
      known_bot = context[:known_bot] || {}
      cross_channel = context[:cross_channel_count] || 0

      if known_bot[:bot] && known_bot[:sources]&.size.to_i >= 2
        components[:known_bot_multi] = { value: known_bot[:sources].size, weight: 1.0, contribution: 1.0, sources: known_bot[:sources] }
        return true
      end

      if cross_channel >= 100
        components[:cross_channel_100plus] = { value: cross_channel, weight: 1.0, contribution: 1.0 }
        return true
      end

      false
    end

    # === Step 3a: Known bot (single source) ===

    def score_known_bot(known_bot, components)
      return 0.0 unless known_bot&.dig(:bot)

      # Multi-source handled as definitive above, only single source here
      if known_bot[:sources]&.size == 1
        components[:known_bot_single] = { value: 1, weight: 0.95, contribution: 0.95, sources: known_bot[:sources] }
        return 0.95
      end

      0.0
    end

    # === Step 3b: Chat behavior signals ===

    def score_chat_behavior(chat_stats, components)
      return 0.0 unless chat_stats

      total = 0.0

      if chat_stats[:cv_timing] && chat_stats[:cv_timing] < 0.4
        weight = 0.70
        components[:cv_timing] = { value: chat_stats[:cv_timing].round(4), weight: weight, contribution: weight }
        total += weight
      end

      if chat_stats[:entropy] && chat_stats[:entropy] < 3.0
        weight = 0.70
        components[:entropy] = { value: chat_stats[:entropy].round(4), weight: weight, contribution: weight }
        total += weight
      end

      if chat_stats[:custom_emote_ratio] && chat_stats[:message_count].to_i >= 8 && chat_stats[:custom_emote_ratio] == 0.0
        weight = 0.35
        components[:zero_custom_emotes] = { value: 0, weight: weight, contribution: weight, messages: chat_stats[:message_count] }
        total += weight
      end

      total
    end

    # === Step 3c: Profile signals ===

    def score_profile(profile, components)
      return 0.0 unless profile

      total = 0.0

      # High signals
      if profile[:profile_view_count]&.zero?
        weight = 0.65
        components[:profile_view_zero] = { value: 0, weight: weight, contribution: weight }
        total += weight
      end

      if profile[:followers_count]&.zero?
        weight = 0.65
        components[:followers_zero] = { value: 0, weight: weight, contribution: weight }
        total += weight
      end

      if profile[:created_at] && profile[:created_at] > 7.days.ago
        weight = 0.60
        components[:account_age_7d] = { value: ((Time.current - profile[:created_at]) / 1.day).round(1), weight: weight, contribution: weight }
        total += weight
      elsif profile[:created_at] && profile[:created_at] > 30.days.ago
        weight = 0.40
        components[:account_age_30d] = { value: ((Time.current - profile[:created_at]) / 1.day).round(1), weight: weight, contribution: weight }
        total += weight
      end

      # Medium signals
      if profile[:follows_count]&.zero?
        weight = 0.40
        components[:follows_zero] = { value: 0, weight: weight, contribution: weight }
        total += weight
      elsif profile[:follows_count].to_i > 1000
        weight = 0.35
        components[:follows_excessive] = { value: profile[:follows_count], weight: weight, contribution: weight }
        total += weight
      end

      if profile[:description].nil?
        weight = 0.30
        components[:description_null] = { value: nil, weight: weight, contribution: weight }
        total += weight
      end

      # Low signals
      if profile[:banner_image_url].nil?
        weight = 0.15
        components[:banner_null] = { value: nil, weight: weight, contribution: weight }
        total += weight
      end

      if profile[:videos_count]&.zero?
        weight = 0.10
        components[:videos_zero] = { value: 0, weight: weight, contribution: weight }
        total += weight
      end

      if profile[:last_broadcast_at].nil?
        weight = 0.10
        components[:last_broadcast_null] = { value: nil, weight: weight, contribution: weight }
        total += weight
      end

      total
    end

    # === Step 4: Anti-bot signals (negative) ===

    def score_anti_bot(irc_tags, components)
      return 0.0 unless irc_tags

      total = 0.0

      # Subscriber
      badge_info = irc_tags[:badge_info].to_s
      sub_months = extract_sub_months(badge_info)
      if sub_months >= 24
        # Check if self-purchased or gifted (approximate: if subscriber_status present = has sub)
        weight = -0.8
        components[:subscriber_24plus] = { value: sub_months, weight: weight, contribution: weight }
        total += weight
      elsif irc_tags[:subscriber_status].present?
        weight = -0.5
        components[:subscriber] = { value: true, weight: weight, contribution: weight }
        total += weight
      end

      # Returning chatter
      if irc_tags[:returning_chatter] == true || irc_tags[:returning_chatter] == "1"
        weight = -0.3
        components[:returning_chatter] = { value: true, weight: weight, contribution: weight }
        total += weight
      end

      # Bits used (proxy for prediction/poll/hype train engagement)
      if irc_tags[:bits_used].to_i > 0
        weight = -0.6
        components[:bits_used] = { value: irc_tags[:bits_used], weight: weight, contribution: weight }
        total += weight
      end

      total
    end

    # === Helpers ===

    def extract_sub_months(badge_info)
      match = badge_info.match(/subscriber\/(\d+)/)
      match ? match[1].to_i : 0
    end

    def classify(score)
      CLASSIFICATION_THRESHOLDS.each do |label, lower, upper|
        return label if score >= lower && score < upper
      end
      "confirmed_bot"
    end

    def calculate_confidence(context, components)
      available = 0
      total_possible = 3 # known_bot, chat, profile

      available += 1 if context[:known_bot]
      available += 1 if context[:chat_stats] && context[:chat_stats][:message_count].to_i >= 3
      available += 1 if context[:profile]

      (available.to_f / total_possible).round(2)
    end

    def build_result(score, components, confidence)
      Result.new(
        score: score.round(4),
        classification: classify(score),
        components: components,
        confidence: confidence.round(2)
      )
    end
  end
end
