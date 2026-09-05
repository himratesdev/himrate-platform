# frozen_string_literal: true

require "rails_helper"

RSpec.describe Farm::CaptureSetSyncWorker do
  let(:helix) { instance_double(Twitch::HelixClient) }
  let(:capture_set) { instance_double(Farm::CaptureSet) }
  let(:stats) { Farm::CaptureSet::Stats.new(joined: 0, parted: 0, kept: 0, skipped_incomplete: 0) }

  before do
    allow(Twitch::HelixClient).to receive(:new).and_return(helix)
    allow(Farm::CaptureSet).to receive(:new).and_return(capture_set)
    allow(capture_set).to receive(:sync).and_return(stats)
    Flipper.enable(:farm_capture)
  end

  def stream(login, game_id: "493057", viewers: 10)
    { "user_login" => login, "game_id" => game_id, "viewer_count" => viewers }
  end

  it "pages every enabled category to the end and syncs the union (strict game_id, lowercased logins)" do
    FarmCaptureCategory.create!(game_id: "493057", game_name: "PUBG")
    FarmCaptureCategory.create!(game_id: "509658", game_name: "JC", languages: %w[ru en])
    FarmCaptureCategory.create!(game_id: "999", game_name: "off", enabled: false)

    expect(helix).to receive(:get_streams_page)
      .with(game_id: "493057", languages: nil, first: 100, after: nil)
      .and_return({ "data" => [ stream("Alpha"), stream("leak", game_id: "29595") ], "cursor" => "c1" })
    expect(helix).to receive(:get_streams_page)
      .with(game_id: "493057", languages: nil, first: 100, after: "c1")
      .and_return({ "data" => [ stream("bravo") ], "cursor" => nil })
    expect(helix).to receive(:get_streams_page)
      .with(game_id: "509658", languages: %w[ru en], first: 100, after: nil)
      .and_return({ "data" => [ stream("charlie", game_id: "509658") ], "cursor" => nil })

    described_class.new.perform

    expect(capture_set).to have_received(:sync).with(
      live: { "alpha" => "493057", "bravo" => "493057", "charlie" => "509658" },
      configured_game_ids: Set["493057", "509658"], # the disabled 999 is NOT configured → its channels get parted
      complete_game_ids: Set["493057", "509658"],
      excluded: Set.new
    )
  end

  it "marks a category incomplete when a Helix page fails, keeping the others authoritative" do
    FarmCaptureCategory.create!(game_id: "493057", game_name: "PUBG")
    FarmCaptureCategory.create!(game_id: "32399", game_name: "CS")
    allow(helix).to receive(:get_streams_page).with(hash_including(game_id: "493057")).and_return(nil)
    allow(helix).to receive(:get_streams_page).with(hash_including(game_id: "32399"))
      .and_return({ "data" => [ stream("cs_guy", game_id: "32399") ], "cursor" => nil })

    described_class.new.perform

    expect(capture_set).to have_received(:sync).with(
      live: { "cs_guy" => "32399" }, configured_game_ids: Set["493057", "32399"],
      complete_game_ids: Set["32399"], excluded: Set.new
    )
  end

  it "marks a category incomplete when MAX_PAGES runs out with a cursor still present (S1 — never truncate-as-complete)" do
    FarmCaptureCategory.create!(game_id: "509658", game_name: "JC")
    allow(helix).to receive(:get_streams_page)
      .and_return({ "data" => [ stream("endless", game_id: "509658") ], "cursor" => "more" })
    expect(Rails.logger).to receive(:warn).with(/MAX_PAGES=#{described_class::MAX_PAGES} exhausted/)

    described_class.new.perform

    expect(helix).to have_received(:get_streams_page).exactly(described_class::MAX_PAGES).times
    expect(capture_set).to have_received(:sync).with(
      live: {}, configured_game_ids: Set["509658"], complete_game_ids: Set.new, excluded: Set.new
    )
  end

  it "applies the per-category viewer floor" do
    FarmCaptureCategory.create!(game_id: "493057", game_name: "PUBG", viewer_floor: 50)
    allow(helix).to receive(:get_streams_page)
      .and_return({ "data" => [ stream("big", viewers: 51), stream("small", viewers: 49) ], "cursor" => nil })

    described_class.new.perform

    expect(capture_set).to have_received(:sync).with(hash_including(live: { "big" => "493057" }))
  end

  it "excludes channels the bot-detection IRC already holds (monitored + active + open Stream)" do
    FarmCaptureCategory.create!(game_id: "493057", game_name: "PUBG")
    held = Channel.create!(twitch_id: "1", login: "held_ru", is_monitored: true)
    Stream.create!(channel: held, started_at: 1.hour.ago)
    Channel.create!(twitch_id: "2", login: "offline_ru", is_monitored: true) # no open stream → not held
    gone = Channel.create!(twitch_id: "3", login: "deleted_ru", is_monitored: true, deleted_at: 1.day.ago)
    Stream.create!(channel: gone, started_at: 1.hour.ago) # soft-deleted → bin/irc_monitor skips it too (N2)
    allow(helix).to receive(:get_streams_page)
      .and_return({ "data" => [ stream("held_ru"), stream("offline_ru"), stream("deleted_ru") ], "cursor" => nil })

    described_class.new.perform

    expect(capture_set).to have_received(:sync).with(hash_including(excluded: Set["held_ru"]))
  end

  it "still syncs with an empty live set when every category is disabled, so all channels are released (M1)" do
    FarmCaptureCategory.create!(game_id: "493057", game_name: "PUBG", enabled: false)

    described_class.new.perform

    expect(capture_set).to have_received(:sync).with(
      live: {}, configured_game_ids: Set.new, complete_game_ids: Set.new, excluded: Set.new
    )
  end

  it "is a no-op when the farm_capture flag is disabled" do
    Flipper.disable(:farm_capture)
    FarmCaptureCategory.create!(game_id: "493057", game_name: "PUBG")

    described_class.new.perform

    expect(capture_set).not_to have_received(:sync)
  end
end
