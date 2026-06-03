# frozen_string_literal: true

require "rails_helper"

RSpec.describe TrustIndex::ErvCalculator do
  it "computes ERV for TI=72, CCV=5000" do
    result = described_class.compute(ti_score: 72, ccv: 5000, confidence: 0.9)
    expect(result[:erv_count]).to eq(3600)
    expect(result[:erv_percent]).to eq(72.0)
  end

  # Phase 4 J PR-D: top tier (90-100) gets «Аудитория реальная» / «Audience is
  # real» per PO directive 2026-06-02. Mid-green band (80-89) keeps «Аномалий не
  # замечено» neutral phrasing. Both stay green-colored — no downstream client
  # break.
  it "assigns top-tier «Аудитория реальная» for ERV ≥ 90 (Phase 4 J PR-D)" do
    result = described_class.compute(ti_score: 95, ccv: 1000, confidence: 0.9)
    expect(result[:label]).to eq("Аудитория реальная")
    expect(result[:label_en]).to eq("Audience is real")
    expect(result[:label_color]).to eq("green")
  end

  it "assigns excellent at exactly TI=90 (boundary lower)" do
    result = described_class.compute(ti_score: 90, ccv: 1000, confidence: 0.9)
    expect(result[:label]).to eq("Аудитория реальная")
  end

  it "assigns excellent at TI=100 (boundary upper)" do
    result = described_class.compute(ti_score: 100, ccv: 1000, confidence: 0.9)
    expect(result[:label]).to eq("Аудитория реальная")
  end

  it "assigns green label for ERV 85% (mid-green band 80-89)" do
    result = described_class.compute(ti_score: 85, ccv: 1000, confidence: 0.9)
    expect(result[:label]).to eq("Аномалий не замечено")
    expect(result[:label_color]).to eq("green")
  end

  it "assigns green at exactly TI=89 (boundary upper of mid-green)" do
    result = described_class.compute(ti_score: 89, ccv: 1000, confidence: 0.9)
    expect(result[:label]).to eq("Аномалий не замечено")
  end

  it "assigns green at exactly TI=80 (boundary lower of mid-green)" do
    result = described_class.compute(ti_score: 80, ccv: 1000, confidence: 0.9)
    expect(result[:label]).to eq("Аномалий не замечено")
  end

  it "assigns yellow label for ERV 55%" do
    result = described_class.compute(ti_score: 55, ccv: 1000, confidence: 0.9)
    expect(result[:label]).to eq("Аномалия онлайна")
    expect(result[:label_color]).to eq("yellow")
  end

  it "assigns red label for ERV 30%" do
    result = described_class.compute(ti_score: 30, ccv: 1000, confidence: 0.9)
    expect(result[:label]).to eq("Значительная аномалия онлайна")
    expect(result[:label_color]).to eq("red")
  end

  it "returns point estimate for confidence >= 0.7" do
    result = described_class.compute(ti_score: 80, ccv: 5000, confidence: 0.8)
    expect(result[:confidence_display][:type]).to eq("point")
  end

  it "returns range ±15% for confidence 0.3-0.6" do
    result = described_class.compute(ti_score: 80, ccv: 5000, confidence: 0.5)
    expect(result[:confidence_display][:type]).to eq("range")
    expect(result[:confidence_display][:low]).to be < result[:erv_count]
    expect(result[:confidence_display][:high]).to be > result[:erv_count]
  end

  it "returns insufficient for confidence < 0.3" do
    result = described_class.compute(ti_score: 80, ccv: 5000, confidence: 0.2)
    expect(result[:confidence_display][:type]).to eq("insufficient")
  end

  it "returns nil for CCV=0" do
    result = described_class.compute(ti_score: 80, ccv: 0, confidence: 0.9)
    expect(result[:erv_count]).to be_nil
  end

  it "clamps ERV percent to 0-100" do
    result = described_class.compute(ti_score: 105, ccv: 1000, confidence: 0.9)
    expect(result[:erv_percent]).to eq(100.0)
  end
end
