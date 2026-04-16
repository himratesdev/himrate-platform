# frozen_string_literal: true

# TASK-038 FR-016: Rule-based recommendation engine.
# Evaluates 10 rules, sorts by priority, filters dismissed, takes max 5.
# Reads metadata from RecommendationTemplate (DB).

module Hs
  class RecommendationService
    DEFAULT_MAX = 5

    # Map template.component → weights key (Architect Q3: sort tiebreaker by component weight DESC)
    COMPONENT_WEIGHT_KEY = {
      "trust_index" => :ti,
      "stability" => :stability,
      "engagement" => :engagement,
      "growth" => :growth,
      "consistency" => :consistency
    }.freeze

    def initialize(
      ti_drop_detector: TiDropDetector.new,
      component_percentile_service: nil,
      weights_loader: nil
    )
      @ti_drop_detector = ti_drop_detector
      @component_percentile_service_class = component_percentile_service || ComponentPercentileService
      @weights_loader = weights_loader || WeightsLoader.new
    end

    def call(channel:, user:, health_score_record:)
      return [] unless health_score_record
      return [] unless Flipper.enabled?(:hs_recommendations, user)

      context = build_context(channel, health_score_record)
      dismissed_ids = dismissed_rule_ids(user, channel) if user
      dismissed_ids ||= []

      templates = RecommendationTemplate.enabled.where.not(rule_id: dismissed_ids)

      applicable = templates.select do |template|
        RecommendationRules.evaluate(template.rule_id, context)
      end

      category_key = health_score_record.category || Hs::CategoryMapper.default_key
      category_weights = safe_load_weights(category_key)
      sorted = sort_recommendations(applicable, category_weights)
      sorted.first(max_recommendations).map { |t| serialize(t) }
    end

    private

    def build_context(channel, hs_record)
      components = {
        ti: hs_record.ti_component&.to_f,
        stability: hs_record.stability_component&.to_f,
        engagement: hs_record.engagement_component&.to_f,
        growth: hs_record.growth_component&.to_f,
        consistency: hs_record.consistency_component&.to_f
      }

      category_key = hs_record.category || Hs::CategoryMapper.default_key
      component_percentiles = @component_percentile_service_class.new(channel).call(category_key)

      {
        components: components,
        components_percentile: component_percentiles,
        ti_drop_pts: @ti_drop_detector.call(channel),
        ti_drop_threshold: @ti_drop_detector.ti_drop_threshold_pts,
        latest_ti: components[:ti],
        followers_delta: followers_delta_30d(channel)
      }
    end

    def followers_delta_30d(channel)
      snapshots = FollowerSnapshot
        .where(channel_id: channel.id)
        .where("timestamp > ?", 30.days.ago)
        .order(:timestamp)
        .pluck(:followers_count)

      return nil if snapshots.size < 2

      snapshots.last.to_i - snapshots.first.to_i
    end

    def dismissed_rule_ids(user, channel)
      DismissedRecommendation
        .where(user_id: user.id, channel_id: channel.id)
        .pluck(:rule_id)
    end

    # Architect Q3: Critical>High>Medium>Low → component weight DESC (TI first at ties) → rule_id ASC
    def sort_recommendations(templates, category_weights)
      templates.sort_by do |t|
        weight_key = COMPONENT_WEIGHT_KEY[t.component]
        comp_weight = weight_key ? category_weights[weight_key].to_f : 0.0
        [
          RecommendationRules::PRIORITY_ORDER.fetch(t.priority, 99),
          -comp_weight,  # negative for DESC
          t.rule_id
        ]
      end
    end

    def safe_load_weights(category_key)
      @weights_loader.call(category_key)
    rescue WeightsLoader::MissingWeights
      # Fallback: equal weights if config missing (degraded mode, still sortable)
      WeightsLoader::COMPONENTS.index_with(0.2)
    end

    def serialize(template)
      {
        rule_id: template.rule_id,
        component: template.component,
        priority: template.priority,
        i18n_key: template.i18n_key,
        # expected_impact is stored as i18n key (S1 fix). Return key + localized text.
        expected_impact_key: template.expected_impact,
        expected_impact: template.expected_impact.present? ? I18n.t(template.expected_impact, default: nil) : nil,
        cta_action: template.cta_action
      }
    end

    def max_recommendations
      @max_recommendations ||= (
        SignalConfiguration
          .where(signal_type: "recommendation", category: "default", param_name: "max_recommendations")
          .pick(:param_value)&.to_i || DEFAULT_MAX
      )
    end
  end
end
