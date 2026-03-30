# frozen_string_literal: true

require "rails_helper"

RSpec.describe BotDetection::Scorer do
  let(:scorer) { described_class.new(known_bot_service: known_bot_service) }
  let(:known_bot_service) { instance_double(KnownBotService) }

  let(:base_context) do
    {
      irc_tags: { user_type: nil, subscriber_status: nil, returning_chatter: false, vip: false, badge_info: nil, bits_used: 0 },
      chat_stats: { message_count: 10, cv_timing: nil, entropy: nil, custom_emote_ratio: nil },
      known_bot: { bot: false, confidence: 0.0, sources: [] },
      cross_channel_count: 0,
      profile: nil
    }
  end

  # AC-04: Moderator/VIP = score 0.0 (whitelist)
  describe "whitelist" do
    it "returns 0.0 for moderator" do
      ctx = base_context.merge(irc_tags: base_context[:irc_tags].merge(user_type: "mod"))
      result = scorer.score("mod_user", ctx)
      expect(result.score).to eq(0.0)
      expect(result.classification).to eq("human")
    end

    it "returns 0.0 for VIP" do
      ctx = base_context.merge(irc_tags: base_context[:irc_tags].merge(vip: true))
      result = scorer.score("vip_user", ctx)
      expect(result.score).to eq(0.0)
    end

    %w[partner affiliate staff].each do |type|
      it "returns 0.0 for #{type}" do
        ctx = base_context.merge(irc_tags: base_context[:irc_tags].merge(user_type: type))
        result = scorer.score("#{type}_user", ctx)
        expect(result.score).to eq(0.0)
      end
    end
  end

  # AC-02: Known bot (2+ sources) = score 1.0
  describe "definitive signals" do
    it "returns 1.0 for known bot in 2+ databases" do
      ctx = base_context.merge(
        known_bot: { bot: true, confidence: 0.95, sources: %w[commanderroot twitchinsights] }
      )
      result = scorer.score("bot_user", ctx)
      expect(result.score).to eq(1.0)
      expect(result.classification).to eq("confirmed_bot")
    end

    it "returns 1.0 for 100+ channels/day" do
      ctx = base_context.merge(cross_channel_count: 150)
      result = scorer.score("multi_channel_bot", ctx)
      expect(result.score).to eq(1.0)
      expect(result.classification).to eq("confirmed_bot")
    end
  end

  # AC-03: Known bot (1 source) = score 0.95
  describe "very high signals" do
    it "returns 0.95 for known bot in 1 database" do
      ctx = base_context.merge(
        known_bot: { bot: true, confidence: 0.75, sources: %w[commanderroot] }
      )
      result = scorer.score("single_source_bot", ctx)
      expect(result.score).to eq(0.95)
      expect(result.classification).to eq("confirmed_bot")
    end
  end

  # AC-06: Empty profile = score >= 0.60
  describe "profile signals" do
    it "scores high for empty profile" do
      ctx = base_context.merge(
        profile: {
          created_at: 3.days.ago,
          profile_view_count: 0,
          followers_count: 0,
          follows_count: 0,
          description: nil,
          banner_image_url: nil,
          videos_count: 0,
          last_broadcast_at: nil
        }
      )
      result = scorer.score("empty_profile", ctx)
      expect(result.score).to be >= 0.60
      expect(result.components).to include(:profile_view_zero, :followers_zero, :account_age_7d)
    end
  end

  # AC-05: Subscriber 24+ reduces by -0.8
  describe "anti-bot signals" do
    it "reduces score for 24+ month subscriber" do
      ctx = base_context.merge(
        known_bot: { bot: true, confidence: 0.75, sources: %w[commanderroot] },
        irc_tags: base_context[:irc_tags].merge(badge_info: "subscriber/36", subscriber_status: "1")
      )
      result = scorer.score("sub_bot", ctx)
      # 0.95 (known bot single) - 0.8 (sub 24+) = 0.15
      expect(result.score).to be < 0.95
      expect(result.components).to include(:subscriber_24plus)
    end

    it "reduces score for returning chatter" do
      ctx = base_context.merge(
        irc_tags: base_context[:irc_tags].merge(returning_chatter: true)
      )
      # No positive signals + returning chatter = 0.0 (clamped)
      result = scorer.score("returning_user", ctx)
      expect(result.score).to eq(0.0)
      expect(result.classification).to eq("human")
    end
  end

  # AC-07: Classification matches BFT thresholds
  describe "classification" do
    it "classifies Human for score < 0.2" do
      result = scorer.score("clean_user", base_context)
      expect(result.score).to be < 0.2
      expect(result.classification).to eq("human")
    end

    it "classifies confirmed_bot for definitive" do
      ctx = base_context.merge(cross_channel_count: 200)
      result = scorer.score("bot", ctx)
      expect(result.classification).to eq("confirmed_bot")
    end
  end

  # AC-08: Components jsonb
  describe "components" do
    it "stores signal details in components" do
      ctx = base_context.merge(
        known_bot: { bot: true, confidence: 0.95, sources: %w[commanderroot twitchinsights] }
      )
      result = scorer.score("bot", ctx)
      expect(result.components).to have_key(:known_bot_multi)
      expect(result.components[:known_bot_multi][:sources]).to eq(%w[commanderroot twitchinsights])
    end
  end

  # AC-12: Score clamped to [0.0, 1.0]
  describe "clamping" do
    it "clamps negative scores to 0.0" do
      ctx = base_context.merge(
        irc_tags: base_context[:irc_tags].merge(
          returning_chatter: true,
          subscriber_status: "1",
          badge_info: "subscriber/36",
          bits_used: 100
        )
      )
      result = scorer.score("generous_user", ctx)
      expect(result.score).to eq(0.0)
    end
  end

  # AC-11: Graceful degradation
  describe "graceful degradation" do
    it "scores with IRC + known bot only (no profile)" do
      ctx = base_context.merge(profile: nil)
      result = scorer.score("no_profile_user", ctx)
      expect(result.confidence).to be < 1.0
      expect(result.score).to be_a(Float)
    end
  end
end
