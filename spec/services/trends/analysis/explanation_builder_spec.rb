# frozen_string_literal: true

require "rails_helper"

RSpec.describe Trends::Analysis::ExplanationBuilder do
  it "generates rising_with_improvements narrative when improvements present" do
    trend = { direction: "rising", delta: 4.2 }
    improvements = [ { name: "auth_ratio", delta: 2.5 }, { name: "engagement", delta: 1.8 } ]
    result = described_class.call(trend: trend, improvement_signals: improvements)

    expect(result[:explanation_en]).to include("up")
    expect(result[:explanation_ru]).to include("вырос")
    expect(result[:improvement_signals]).to eq(improvements)
  end

  it "falls back to generic when direction=rising but no improvements" do
    trend = { direction: "rising", delta: 4.2 }
    result = described_class.call(trend: trend, improvement_signals: [])

    expect(result[:explanation_en]).to include("trending up")
  end

  it "generates declining_with_degradations narrative" do
    trend = { direction: "declining", delta: -5.1 }
    degradations = [ { name: "auth_ratio", delta: -3.0 } ]
    result = described_class.call(trend: trend, degradation_signals: degradations)

    expect(result[:explanation_en]).to include("down")
    expect(result[:explanation_ru]).to include("снизился")
  end

  it "uses flat narrative when direction=flat" do
    trend = { direction: "flat", delta: 0.1 }
    result = described_class.call(trend: trend, metric_key: "trends.metric.erv")

    expect(result[:explanation_en]).to include("stable")
  end

  it "caps signal list at top 3" do
    trend = { direction: "rising", delta: 5 }
    improvements = (1..5).map { |i| { name: "signal_#{i}", delta: i } }
    result = described_class.call(trend: trend, improvement_signals: improvements)

    expect(result[:improvement_signals].size).to eq(3)
  end

  it "resolves the metric name per-locale — no request-locale leak into both narratives (T1-074 surface-audit)" do
    trend = { direction: "rising", delta: 4.2 }
    result = I18n.with_locale(:ru) { described_class.call(trend: trend, metric_key: "trends.metric.trust_index") }

    expect(result[:explanation_en]).to include("Authenticity")
    expect(result[:explanation_ru]).to include("Уровень подлинности")
  end
end
