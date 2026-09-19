# frozen_string_literal: true

require "rails_helper"

RSpec.describe Discover::LiveNowQuery do
  let(:user) { create(:user) }

  def live_stream(channel)
    create(:stream, channel: channel, started_at: 1.hour.ago, ended_at: nil)
  end

  describe "#call — TI-v2 engine-aware audience" do
    it "reads the NATIVE v2 count/authenticity/band off a v2 latest row (regression: no null audience post-cutover)" do
      channel = create(:channel, login: "v2chan", display_name: "V2 Chan", is_monitored: true)
      live_stream(channel)
      create(:trust_index_history, :v2, channel: channel, stream: nil,
                                         ccv: 5000, erv: 3600, authenticity: 72.0,
                                         band_row: 3, band_color: "green", calculated_at: 1.minute.ago)

      # Surface-audit sweep: erv_label resolves under the REQUEST locale (was force-:ru)
      row = I18n.with_locale(:ru) { described_class.new(user: user).call }.find { |r| r[:login] == "v2chan" }

      expect(row).to be_present
      expect(row[:shown_viewers]).to eq(5000)      # V (engine input)
      expect(row[:real_viewers]).to eq(3600)        # NATIVE erv, not ccv × pct
      expect(row[:erv_percent]).to eq(72.0)         # authenticity
      expect(row[:erv_label]).to eq("Аудитория реальная") # band_row 3 → band.green_real (request locale ru)
      expect(row[:erv_label_color]).to eq("green")
      # The scale hint behind the label — resolved server-side, same key derivation, same locale.
      expect(row[:erv_tooltip]).to eq(I18n.t("band.tooltip.green_real", locale: :ru))

      en_row = I18n.with_locale(:en) { described_class.new(user: user).call }.find { |r| r[:login] == "v2chan" }
      expect(en_row[:erv_label]).to eq("Audience is real") # same key, EN request locale
      expect(en_row[:erv_tooltip]).to eq(I18n.t("band.tooltip.green_real", locale: :en))
    end

    # V1-RETIRE: the wire keys erv_percent/ti_score are legacy NAMES only — both carry
    # authenticity now (landing/discover.js reads them; renaming the wire is a separate task).
    it "carries authenticity under both legacy wire names (erv_percent AND ti_score)" do
      channel = create(:channel, login: "wirechan", display_name: "Wire Chan", is_monitored: true)
      live_stream(channel)
      create(:trust_index_history, channel: channel, stream: nil,
                                    ccv: 1000, erv: 800, authenticity: 80.0,
                                    calculated_at: 1.minute.ago)

      row = described_class.new(user: user).call.find { |r| r[:login] == "wirechan" }

      expect(row).to be_present
      expect(row[:shown_viewers]).to eq(1000)
      expect(row[:real_viewers]).to eq(800)         # NATIVE erv
      expect(row[:erv_percent]).to eq(80.0)         # authenticity under the legacy name
      expect(row[:ti_score]).to eq(80.0)            # same value — legacy wire alias
      expect(row[:erv_label]).to be_present
    end

    it "ranks channels by real audience (native erv DESC)" do
      big = create(:channel, login: "big", is_monitored: true)
      small = create(:channel, login: "small", is_monitored: true)
      live_stream(big)
      live_stream(small)
      create(:trust_index_history, :v2, channel: big, stream: nil, ccv: 9000, erv: 8000, calculated_at: 1.minute.ago)
      create(:trust_index_history, :v2, channel: small, stream: nil, ccv: 1000, erv: 500,
                                         authenticity: 50.0, calculated_at: 1.minute.ago)

      logins = described_class.new(user: user).call.map { |r| r[:login] }
      expect(logins.index("big")).to be < logins.index("small") # 8000 real > 500 real
    end

    it "ignores a v2 row with no usable audience (erv NULL) and channels with only ghost rows" do
      channel = create(:channel, login: "ghost", is_monitored: true)
      live_stream(channel)
      create(:trust_index_history, :v2, channel: channel, stream: nil, erv: nil, authenticity: nil,
                                         calculated_at: 1.minute.ago)

      row = described_class.new(user: user).call.find { |r| r[:login] == "ghost" }
      # the latest usable-row filter finds none → LEFT JOIN yields NULL audience, sorted last but present
      expect(row&.dig(:real_viewers)).to be_nil if row
    end
  end

  # WEB-CONSOLIDATION home board: every param but `limit` used to be dropped silently.
  describe "#call — filters" do
    def board_channel(login, game: "Dota 2", language: "ru", erv: 1000, band_row: 4, band_color: "green",
                      verdict: true)
      channel = create(:channel, login: login, is_monitored: true)
      create(:stream, channel: channel, started_at: 1.hour.ago, ended_at: nil, game_name: game, language: language)
      if verdict
        create(:trust_index_history, channel: channel, stream: nil, ccv: erv * 2, erv: erv,
                                      band_row: band_row, band_color: band_color, calculated_at: 1.minute.ago)
      end
      channel
    end

    # Positional (no keywords) so a braceless `logins(game: "x")` binds to `filters`.
    def logins(filters, limit = described_class::LIMIT)
      described_class.new(user: nil, limit: limit, filters: filters).call.map { |r| r[:login] }
    end

    it "answers a guest (user: nil) with nothing marked as watched" do
      board_channel("guest_seen")

      rows = described_class.new(user: nil).call
      expect(rows.map { |r| r[:is_watched_by_user] }).to eq([ false ])
    end

    it "filters by the category of the current broadcast, case-insensitively" do
      board_channel("dota_a", game: "Dota 2")
      board_channel("cs_a", game: "Counter-Strike 2")

      expect(logins(game: "dota 2")).to eq(%w[dota_a])
    end

    it "judges the category on the CURRENT broadcast, not on a stale unclosed duplicate" do
      switched = board_channel("switched", game: "Just Chatting")
      create(:stream, channel: switched, started_at: 5.hours.ago, ended_at: nil, game_name: "Dota 2")

      expect(logins(game: "Dota 2")).to be_empty
      expect(logins(game: "Just Chatting")).to eq(%w[switched])
    end

    it "filters by broadcast language, case-insensitively" do
      board_channel("ru_a", language: "ru")
      board_channel("en_a", language: "en")

      expect(logins(language: "RU")).to eq(%w[ru_a])
    end

    it "filters by one or several verdict colours" do
      board_channel("red_a", band_row: 1, band_color: "red", erv: 300)
      board_channel("amber_a", band_row: 6, band_color: "amber", erv: 200)
      board_channel("green_a", band_row: 3, band_color: "green", erv: 100)

      expect(logins(band: "red")).to eq(%w[red_a])
      expect(logins(band: "red, AMBER")).to eq(%w[red_a amber_a])
    end

    it "counts a channel with no v2 verdict yet as grey — the colour its label already carries" do
      board_channel("no_verdict", verdict: false)
      board_channel("green_b")

      expect(logins(band: "grey")).to eq(%w[no_verdict])
    end

    it "answers that channel with the same colour the filter matched it by" do
      board_channel("no_verdict", verdict: false)

      row = described_class.new(user: nil).call.find { |r| r[:login] == "no_verdict" }
      expect(row[:erv_label_color]).to eq("grey")
    end

    it "ignores unknown verdict colours instead of emptying the board" do
      board_channel("any_a")

      expect(logins(band: "purple,,")).to eq(%w[any_a])
    end

    it "bounds the REAL audience inclusively on both sides" do
      board_channel("small", erv: 100)
      board_channel("mid", erv: 1000)
      board_channel("big", erv: 5000)

      expect(logins(min_viewers: "1000")).to eq(%w[big mid])
      expect(logins(max_viewers: "1000")).to eq(%w[mid small])
      expect(logins(min_viewers: 500, max_viewers: 2000)).to eq(%w[mid])
    end

    it "never lets a channel without a verdict satisfy an audience bound" do
      board_channel("unknown_audience", verdict: false)

      expect(logins(min_viewers: 0)).to be_empty
    end

    it "ignores malformed or negative audience bounds" do
      board_channel("kept")

      expect(logins(min_viewers: "abc", max_viewers: "-5")).to eq(%w[kept])
    end

    it "combines filters and still applies the limit after filtering" do
      board_channel("dota_red_big", game: "Dota 2", band_row: 1, band_color: "red", erv: 900)
      board_channel("dota_red_small", game: "Dota 2", band_row: 1, band_color: "red", erv: 400)
      board_channel("dota_green", game: "Dota 2", band_row: 3, band_color: "green", erv: 5000)
      board_channel("cs_red", game: "Counter-Strike 2", band_row: 1, band_color: "red", erv: 8000)

      expect(logins({ game: "Dota 2", band: "red" }, 1)).to eq(%w[dota_red_big])
    end
  end
end
