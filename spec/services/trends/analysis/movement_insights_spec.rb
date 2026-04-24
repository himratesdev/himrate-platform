# frozen_string_literal: true

require "rails_helper"

RSpec.describe Trends::Analysis::MovementInsights do
  let(:channel) { create(:channel) }
  let(:from) { 30.days.ago }
  let(:to) { Time.current }

  before do
    SignalConfiguration.upsert_all([
      { signal_type: "trends", category: "insights", param_name: "top_n_count", param_value: 3, created_at: Time.current, updated_at: Time.current },
      { signal_type: "trends", category: "insights", param_name: "p0_ti_delta_min_pts", param_value: 5.0, created_at: Time.current, updated_at: Time.current },
      { signal_type: "trends", category: "insights", param_name: "p1_tier_change_recency_days", param_value: 30, created_at: Time.current, updated_at: Time.current },
      { signal_type: "trends", category: "anomaly_freq", param_name: "elevated_threshold_pct", param_value: 50, created_at: Time.current, updated_at: Time.current }
    ], unique_by: %i[signal_type category param_name], on_duplicate: :skip)
  end

  it "returns P0 ti_drop when trend declining above threshold" do
    result = described_class.call(
      channel: channel, from: from, to: to,
      trend: { direction: "declining", delta: -8.0 },
      anomaly_frequency: { verdict: "normal" },
      tier_changes: {},
      top_degradation: { name: "auth_ratio", delta: -3.0 }
    )

    priorities = result.map { |i| i[:priority] }
    expect(priorities).to include("P0")
    expect(result.first[:message_en]).to include("TI dropped")
  end

  it "returns P0 rehabilitation insight when active" do
    result = described_class.call(
      channel: channel, from: from, to: to,
      trend: { direction: "flat", delta: 0 },
      anomaly_frequency: { verdict: "normal" },
      tier_changes: {},
      rehabilitation: { rehabilitation_active: true, progress: { clean_streams_completed: 8, clean_streams_required: 15 }, bonus: { bonus_pts_earned: 3 } }
    )

    expect(result.any? { |i| i[:action] == "view_rehabilitation" }).to be true
  end

  it "returns P1 tier_change insight for recent change" do
    result = described_class.call(
      channel: channel, from: from, to: to,
      trend: { direction: "flat", delta: 0.2 },
      anomaly_frequency: { verdict: "normal" },
      tier_changes: { count: 1, latest: { from_tier: "trusted", to_tier: "needs_review", occurred_at: 5.days.ago } }
    )

    expect(result.any? { |i| i[:priority] == "P1" && i[:action] == "view_tier_change" }).to be true
  end

  it "returns flat insight when nothing notable" do
    result = described_class.call(
      channel: channel, from: from, to: to,
      trend: { direction: "flat", delta: 0.1 },
      anomaly_frequency: { verdict: "normal" },
      tier_changes: {}
    )

    expect(result.size).to eq(1)
    expect(result.first[:priority]).to eq("P3")
    expect(result.first[:message_en]).to include("No notable")
  end

  it "CR M-2: per-locale signal name (no locale-leak between message_ru/en)" do
    # signals.auth_ratio не translated → fallback = 'Auth ratio' (humanize) в both locales.
    result = described_class.call(
      channel: channel, from: from, to: to,
      trend: { direction: "declining", delta: -8.0 },
      anomaly_frequency: { verdict: "normal" },
      tier_changes: {},
      top_degradation: { name: "auth_ratio", delta: -3.0 }
    )

    ti_drop = result.find { |i| i[:action] == "view_components" }
    expect(ti_drop[:message_ru]).to include("TI упал")
    expect(ti_drop[:message_en]).to include("TI dropped")
    # Без locale-leak: ru message содержит russian template, en — english template.
    expect(ti_drop[:message_ru]).not_to include("TI dropped")
    expect(ti_drop[:message_en]).not_to include("TI упал")
  end

  it "caps insights at top_n" do
    result = described_class.call(
      channel: channel, from: from, to: to,
      trend: { direction: "declining", delta: -10 },
      anomaly_frequency: { verdict: "elevated", delta_percent: 100 },
      tier_changes: { latest: { from_tier: "trusted", to_tier: "needs_review", occurred_at: 5.days.ago } },
      rehabilitation: { rehabilitation_active: true, progress: {}, bonus: {} },
      top_degradation: { name: "auth_ratio", delta: -5 }
    )

    expect(result.size).to be <= 3
  end

  # TASK-039 Phase E1 SRS §10 alert: trends.movement_insights.duration_p95 > 500ms.
  # CR N-4: payload включает input_signals для p95 outlier debug.
  it "emits trends.movement_insights.completed event с duration + top_priority + input_signals" do
    events = []
    sub = ActiveSupport::Notifications.subscribe("trends.movement_insights.completed") { |_, _, _, _, p| events << p }

    described_class.call(
      channel: channel, from: from, to: to,
      trend: { direction: "declining", delta: -8.0 },
      anomaly_frequency: { verdict: "elevated", delta_percent: 75 },
      tier_changes: { latest: { from_tier: "trusted", to_tier: "needs_review", occurred_at: 5.days.ago } },
      rehabilitation: { rehabilitation_active: true, progress: {}, bonus: {} },
      top_degradation: { name: "auth_ratio", delta: -3.0 }
    )

    expect(events.size).to eq(1)
    payload = events.first
    expect(payload[:channel_id]).to eq(channel.id)
    expect(payload[:insights_count]).to be >= 1
    expect(payload[:top_priority]).to eq("P0")
    expect(payload[:duration_ms]).to be > 0

    expect(payload[:input_signals]).to include(
      trend_direction: "declining",
      trend_delta: -8.0,
      anomaly_verdict: "elevated",
      anomaly_delta_percent: 75,
      tier_change_present: true,
      rehabilitation_active: true
    )
  ensure
    ActiveSupport::Notifications.unsubscribe(sub) if sub
  end
end
