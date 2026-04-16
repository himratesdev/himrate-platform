# frozen_string_literal: true

# TASK-038: Seed data for Health Score Engine.
# Idempotent: uses find_or_create_by + upsert_all.
# Run: rails db:seed or bin/rails runner 'load "db/seeds/health_score.rb"'

module HealthScoreSeeds
  TIERS = [
    { key: "excellent", min_score: 80, max_score: 100, color_name: "green",
      bg_hex: "#E8F5E9", text_hex: "#2E7D32", i18n_key: "hs.label.excellent", display_order: 1 },
    { key: "good", min_score: 60, max_score: 79, color_name: "light_green",
      bg_hex: "#F1F8E9", text_hex: "#558B2F", i18n_key: "hs.label.good", display_order: 2 },
    { key: "average", min_score: 40, max_score: 59, color_name: "yellow",
      bg_hex: "#FFF9C4", text_hex: "#F9A825", i18n_key: "hs.label.average", display_order: 3 },
    { key: "below_average", min_score: 20, max_score: 39, color_name: "orange",
      bg_hex: "#FFF3E0", text_hex: "#E65100", i18n_key: "hs.label.below_average", display_order: 4 },
    { key: "poor", min_score: 0, max_score: 19, color_name: "red",
      bg_hex: "#FFEBEE", text_hex: "#C62828", i18n_key: "hs.label.poor", display_order: 5 }
  ].freeze

  CATEGORIES = [
    # key, display_name, is_default, aliases
    [ "just_chatting", "Just Chatting", false, [ "Just Chatting" ] ],
    [ "league_of_legends", "League of Legends", false, [ "League of Legends" ] ],
    [ "grand_theft_auto_v", "Grand Theft Auto V", false, [ "Grand Theft Auto V", "GTA V", "GTA 5" ] ],
    [ "valorant", "VALORANT", false, [ "VALORANT", "Valorant" ] ],
    [ "counter_strike_2", "Counter-Strike 2", false, [ "Counter-Strike 2", "Counter-Strike: Global Offensive", "CS2", "CSGO" ] ],
    [ "fortnite", "Fortnite", false, [ "Fortnite" ] ],
    [ "minecraft", "Minecraft", false, [ "Minecraft" ] ],
    [ "dota_2", "Dota 2", false, [ "Dota 2" ] ],
    [ "world_of_warcraft", "World of Warcraft", false, [ "World of Warcraft", "WoW" ] ],
    [ "apex_legends", "Apex Legends", false, [ "Apex Legends" ] ],
    [ "call_of_duty_warzone", "Call of Duty: Warzone", false, [ "Call of Duty: Warzone", "Warzone", "COD: Warzone" ] ],
    [ "overwatch_2", "Overwatch 2", false, [ "Overwatch 2" ] ],
    [ "ea_sports_fc_25", "EA Sports FC 25", false, [ "EA Sports FC 25", "FC 25", "FIFA" ] ],
    [ "rocket_league", "Rocket League", false, [ "Rocket League" ] ],
    [ "music", "Music", false, [ "Music" ] ],
    [ "asmr", "ASMR", false, [ "ASMR" ] ],
    [ "art", "Art", false, [ "Art" ] ],
    [ "irl", "IRL", false, [ "Travel & Outdoors", "Food & Drink", "Special Events", "Sports" ] ],
    [ "chess", "Chess", false, [ "Chess" ] ],
    [ "slots", "Slots", false, [ "Slots", "Casino" ] ],
    [ "default", "Other", true, [] ]
  ].freeze

  RECOMMENDATION_RULES = [
    { rule_id: "R-01", component: "engagement", priority: "high",
      i18n_key: "hs.rec.engagement_low", expected_impact: "+8-12",
      cta_action: "settings/chat", display_order: 10 },
    { rule_id: "R-02", component: "engagement", priority: "critical",
      i18n_key: "hs.rec.engagement_critical", expected_impact: "+12-18",
      cta_action: "settings/interactive", display_order: 20 },
    { rule_id: "R-03", component: "consistency", priority: "high",
      i18n_key: "hs.rec.consistency_low", expected_impact: "+5-8",
      cta_action: "settings/schedule", display_order: 30 },
    { rule_id: "R-04", component: "consistency", priority: "critical",
      i18n_key: "hs.rec.consistency_critical", expected_impact: "+10-15",
      cta_action: "settings/schedule", display_order: 40 },
    { rule_id: "R-05", component: "stability", priority: "medium",
      i18n_key: "hs.rec.stability_high_cv", expected_impact: "+5-10",
      cta_action: "learn/tips", display_order: 50 },
    { rule_id: "R-06", component: "growth", priority: "medium",
      i18n_key: "hs.rec.growth_low", expected_impact: "+3-8",
      cta_action: "learn/growth", display_order: 60 },
    { rule_id: "R-07", component: "growth", priority: "high",
      i18n_key: "hs.rec.growth_negative", expected_impact: "+5-12",
      cta_action: "learn/retention", display_order: 70 },
    { rule_id: "R-08", component: "trust_index", priority: "critical",
      i18n_key: "hs.rec.ti_drop_sharp", expected_impact: "recovery 2-3 weeks",
      cta_action: "settings/moderation", display_order: 80 },
    { rule_id: "R-09", component: "trust_index", priority: "critical",
      i18n_key: "hs.rec.ti_penalty_active", expected_impact: "full recovery",
      cta_action: "rehab_plan", display_order: 90 },
    { rule_id: "R-10", component: "all", priority: "low",
      i18n_key: "hs.rec.all_excellent", expected_impact: "maintain",
      cta_action: nil, display_order: 100 }
  ].freeze

  def self.run
    seed_tiers
    seed_categories
    seed_recommendation_templates
  end

  def self.seed_tiers
    TIERS.each do |attrs|
      tier = HealthScoreTier.find_or_initialize_by(key: attrs[:key])
      tier.assign_attributes(attrs)
      tier.save!
    end
  end

  def self.seed_categories
    CATEGORIES.each do |key, display_name, is_default, aliases|
      category = HealthScoreCategory.find_or_initialize_by(key: key)
      category.display_name = display_name
      category.is_default = is_default
      category.save!

      aliases.each do |alias_name|
        HealthScoreCategoryAlias.find_or_create_by!(
          health_score_category: category,
          game_name_alias: alias_name
        )
      end
    end
  end

  def self.seed_recommendation_templates
    RECOMMENDATION_RULES.each do |attrs|
      template = RecommendationTemplate.find_or_initialize_by(rule_id: attrs[:rule_id])
      template.assign_attributes(attrs.merge(enabled: true))
      template.save!
    end
  end
end

HealthScoreSeeds.run if $PROGRAM_NAME.end_with?("runner")
