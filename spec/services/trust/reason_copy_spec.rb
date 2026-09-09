# frozen_string_literal: true

require "rails_helper"

# Guards the copy that makes the verdict readable. Until 2026-09-09 none of it existed on the
# server: the web card carried a partial hardcoded map and silently dropped six of the fourteen
# codes the engine can emit.
RSpec.describe "Reason code copy" do
  # The full emitted set, taken from TrustIndex::V2::ReasonCodeBuilder.
  CODES = %w[
    HARD_NAMED_FRACTION SELF_HISTORY_INFLATION_EVENT SELF_HISTORY_SUSTAINED_INFLATION
    INFLATION_EVENT_CORROBORATION POPULATION_CHAT_DEFICIT SELF_HISTORY_STABLE_CLEAN
    CHATTER_QUALITY_HIGH PROVISIONAL_BASIC ENGAGEMENT_DEFICIT_UNCORROBORATED
    CHATTER_QUALITY_LOW COLD_START_INSUFFICIENT RAID_HOST_EMBED_WINDOW
    UNATTRIBUTED_SURGE WIDE_INTERVAL_THIN_SAMPLE
  ].freeze

  # Words the neutral scale may never use. The accusatory wording is licensed only on the
  # coordination banner, and that copy does not live here.
  FORBIDDEN = { ru: %w[бот накрутк фейк], en: %w[bot fake cheat] }.freeze

  %i[ru en].each do |locale|
    describe locale do
      it "has a title, a body and a tone for every code the engine can emit" do
        missing = CODES.reject do |code|
          key = "reason.#{code.downcase}"
          %w[title text tone].all? { |f| I18n.t("#{key}.#{f}", locale: locale, default: nil).present? }
        end

        expect(missing).to be_empty
      end

      it "never accuses — the neutral scale describes the observation" do
        offenders = CODES.filter_map do |code|
          key = "reason.#{code.downcase}"
          body = [ I18n.t("#{key}.title", locale: locale, default: ""),
                   I18n.t("#{key}.text", locale: locale, default: "") ].join(" ").downcase
          hit = FORBIDDEN[locale].find { |w| body.include?(w) }
          "#{code}: #{hit}" if hit
        end

        expect(offenders).to be_empty
      end

      it "uses only tones the interface knows how to render" do
        tones = CODES.map { |c| I18n.t("reason.#{c.downcase}.tone", locale: locale) }
        expect(tones.uniq).to all(be_in(%w[ok warn dim]))
      end
    end
  end

  it "interpolates the counts the engine publishes with the code" do
    text = I18n.t("reason.hard_named_fraction.text", locale: :ru, n: 14, pct: 14.6)

    expect(text).to include("14", "14.6")
    expect(text).not_to include("%{")
  end

  it "resolves through the API detail objects, in the request locale" do
    channel = create(:channel)
    create(:trust_index_history, channel: channel, engine_version: "v2", ccv: 100,
                                 reason_codes: [ { "code" => "CHATTER_QUALITY_HIGH", "params" => {} } ])

    I18n.with_locale(:en) do
      detail = Trust::ShowService.new(channel: channel, view: :drill_down).call[:reason_codes_detail].first
      expect(detail[:code]).to eq("CHATTER_QUALITY_HIGH")
      expect(detail[:label_key]).to eq("reason.chatter_quality_high")
      expect(detail[:title]).to eq("The chat is alive")
      expect(detail[:tone]).to eq("ok")
    end
  end

  it "degrades an unknown code to code-only instead of breaking the card" do
    channel = create(:channel)
    create(:trust_index_history, channel: channel, engine_version: "v2", ccv: 100,
                                 reason_codes: [ { "code" => "SOMETHING_NEW", "params" => {} } ])

    detail = Trust::ShowService.new(channel: channel, view: :drill_down).call[:reason_codes_detail].first

    expect(detail[:code]).to eq("SOMETHING_NEW")
    expect(detail).not_to have_key(:title)
  end
end
