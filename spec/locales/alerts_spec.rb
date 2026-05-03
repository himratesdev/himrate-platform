# frozen_string_literal: true

require "rails_helper"

# TASK-085 FR-026: smoke test verifying alert i18n catalog presence + parity (RU/EN).
# Backend keeps catalog для contract clarity (frontend extension has parallel copy).

RSpec.describe "Alert i18n catalog (alerts.{ru,en}.yml)" do
  ALERT_KEYS = %w[
    alert.ccv_spike.title
    alert.ccv_spike.detail
    alert.confirmed_raid.title
    alert.confirmed_raid.detail
    alert.confirmed_raid.detail_no_raider
    alert.anomaly_wave.title
    alert.anomaly_wave.detail
    alert.ti_drop.title
    alert.ti_drop.detail
    alert.chatter_to_ccv_anomaly.title
    alert.chatter_to_ccv_anomaly.detail
    alert.chat_entropy_drop.title
    alert.chat_entropy_drop.detail
    alert.erv_divergence.title
    alert.erv_divergence.detail
    alert.severity.info.aria
    alert.severity.yellow.aria
    alert.severity.red.aria
    alert.dismiss
  ].freeze

  it "registers all 19 alert keys в RU locale" do
    ALERT_KEYS.each do |key|
      translation = I18n.t(key, locale: :ru, raise: false, default: nil)
      expect(translation).to be_present, "Missing RU translation for #{key}"
      expect(translation).not_to start_with("translation missing"), "RU key #{key} not registered"
    end
  end

  it "registers all 19 alert keys в EN locale" do
    ALERT_KEYS.each do |key|
      translation = I18n.t(key, locale: :en, raise: false, default: nil)
      expect(translation).to be_present, "Missing EN translation for #{key}"
      expect(translation).not_to start_with("translation missing"), "EN key #{key} not registered"
    end
  end

  it "applies interpolation params correctly (ccv_spike example)" do
    ru = I18n.t("alert.ccv_spike.detail", N: 142, M: 5, From: 5000, To: 12_100, locale: :ru)
    expect(ru).to eq("+142% за 5 мин (рост с 5000 до 12100)")

    en = I18n.t("alert.ccv_spike.detail", N: 142, M: 5, From: 5000, To: 12_100, locale: :en)
    expect(en).to eq("+142% in 5 min (5000 → 12100)")
  end

  it "applies interpolation params correctly (confirmed_raid)" do
    ru = I18n.t("alert.confirmed_raid.detail", raider: "raidersrc", viewers: 250, locale: :ru)
    expect(ru).to eq("Рейд от @raidersrc: 250 зрителей")
  end

  it "fallback template confirmed_raid.detail_no_raider works (EC-21)" do
    ru = I18n.t("alert.confirmed_raid.detail_no_raider", viewers: 100, locale: :ru)
    expect(ru).to eq("Рейд: 100 зрителей")
    en = I18n.t("alert.confirmed_raid.detail_no_raider", viewers: 100, locale: :en)
    expect(en).to eq("Raid: 100 viewers")
  end

  # Note: legal-safe wording verified by lib/tasks/audit.rake via CI lint job (FR-024) —
  # covers app/, spec/, db/seeds/, lib/ across YAML files (ADR-085 D-2).
end
