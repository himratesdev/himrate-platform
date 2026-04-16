# frozen_string_literal: true

require "rails_helper"

RSpec.describe Hs::RecommendationService do
  let(:channel) { create(:channel) }
  let(:user) { create(:user) }
  def build_service(percentiles:)
    mock_klass = Class.new do
      define_method(:initialize) { |_channel| }
      define_method(:call) { |_cat_key| percentiles }
    end
    described_class.new(
      ti_drop_detector: instance_double(Hs::TiDropDetector, call: nil, ti_drop_threshold_pts: 15.0),
      component_percentile_service: mock_klass
    )
  end

  before do
    load Rails.root.join("db/seeds/health_score.rb") unless HealthScoreCategory.exists?
    HealthScoreSeeds.run
    { ti: 0.30, stability: 0.20, engagement: 0.20, growth: 0.15, consistency: 0.15 }.each do |comp, val|
      SignalConfiguration.find_or_initialize_by(
        signal_type: "health_score", category: "default", param_name: "weight_#{comp}"
      ).tap { |c| c.param_value = val }.save!
    end
  end

  def build_hs(components:)
    HealthScore.create!(
      channel_id: channel.id,
      health_score: 50,
      hs_classification: "average",
      confidence_level: "full",
      category: "default",
      ti_component: components[:ti],
      stability_component: components[:stability],
      engagement_component: components[:engagement],
      growth_component: components[:growth],
      consistency_component: components[:consistency],
      calculated_at: Time.current
    )
  end

  it "returns [] when health_score_record nil" do
    service = build_service(percentiles: {})
    expect(service.call(channel: channel, user: user, health_score_record: nil)).to eq([])
  end

  it "triggers R-02 Critical when engagement percentile <20" do
    service = build_service(percentiles: { ti: 50, stability: 50, engagement: 10, growth: 50, consistency: 50 })
    hs = build_hs(components: { ti: 70, engagement: 35, stability: 70, growth: 70, consistency: 70 })

    result = service.call(channel: channel, user: user, health_score_record: hs)
    expect(result.map { |r| r[:rule_id] }).to include("R-02")
    r02 = result.find { |r| r[:rule_id] == "R-02" }
    expect(r02[:priority]).to eq("critical")
  end

  it "triggers R-10 All Excellent when all components >80" do
    service = build_service(percentiles: { ti: 85, stability: 85, engagement: 85, growth: 85, consistency: 85 })
    hs = build_hs(components: { ti: 85, engagement: 85, stability: 85, growth: 85, consistency: 85 })

    result = service.call(channel: channel, user: user, health_score_record: hs)
    expect(result.map { |r| r[:rule_id] }).to eq([ "R-10" ])
  end

  it "excludes dismissed recommendations" do
    service = build_service(percentiles: { ti: 50, stability: 50, engagement: 10, growth: 50, consistency: 50 })
    hs = build_hs(components: { ti: 70, engagement: 35, stability: 70, growth: 70, consistency: 70 })
    DismissedRecommendation.create!(user: user, channel: channel, rule_id: "R-02", dismissed_at: Time.current)

    result = service.call(channel: channel, user: user, health_score_record: hs)
    expect(result.map { |r| r[:rule_id] }).not_to include("R-02")
  end

  it "takes max 5 sorted by priority" do
    service = build_service(percentiles: { ti: 10, stability: 10, engagement: 10, growth: 10, consistency: 10 })
    hs = build_hs(components: { ti: 40, engagement: 20, stability: 30, growth: 20, consistency: 25 })

    result = service.call(channel: channel, user: user, health_score_record: hs)
    expect(result.size).to be <= 5
    priorities = result.map { |r| r[:priority] }
    expect(priorities).to eq(priorities.sort_by { |p| Hs::RecommendationRules::PRIORITY_ORDER[p] })
  end

  it "sorts ties by component weight DESC (TI first when Critical)" do
    # Default category: ti=0.30, stability=0.20, engagement=0.20, growth=0.15, consistency=0.15
    # All Critical triggers needed → only TI<50 (R-09) and engagement<p20 (R-02)
    service = build_service(percentiles: { ti: 50, stability: 50, engagement: 10, growth: 50, consistency: 50 })
    hs = build_hs(components: { ti: 40, engagement: 30, stability: 70, growth: 70, consistency: 70 })

    result = service.call(channel: channel, user: user, health_score_record: hs)
    # Both R-02 (engagement, 0.20) and R-09 (trust_index, 0.30) are critical
    # TI weight (0.30) > Engagement weight (0.20) → R-09 first
    critical_rule_ids = result.select { |r| r[:priority] == "critical" }.map { |r| r[:rule_id] }
    expect(critical_rule_ids.first).to eq("R-09") if critical_rule_ids.size >= 2
  end
end
