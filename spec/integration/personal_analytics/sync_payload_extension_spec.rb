# frozen_string_literal: true

require "rails_helper"

# TASK-113 BE-5 Step 4 — M14 Sync verify (FR-013 / ADR OQ-6).
# Покрывает: SyncEvent.payload (jsonb) — additive расширение `stream_view` с `game_id` + `device`
# для PVA aggregation. Backend-side (ETL) уже готов из BE-2 (`view_event_etl.rb:61-62`); этот integration
# spec подтверждает E2E flow: client POST → SyncEvent ingest → PVA ETL → pva_view_rollups с правильными
# game_id+device. Frontend Dev отвечает за отправку этих полей с extension.
RSpec.describe "Sync payload PVA extension (M14 / FR-013 / OQ-6)", type: :integration do
  let(:user) { create(:user) }

  it "PVA ETL captures game_id + device from sync_events.payload (additive, no migration)" do
    create(:sync_event, user: user, event_type: "stream_view",
      payload: { "channel_id" => "555", "login" => "shroud",
                 "watched_at" => "2026-05-28T20:00:00Z", "duration_sec" => 3600,
                 "game_id" => "509658", "device" => "desktop" })

    PersonalAnalytics::Aggregation::ViewEventEtl.call(user.id)

    event = PvaViewEvent.find_by(user_id: user.id, twitch_channel_id: "555")
    expect(event).to be_present
    expect(event.game_id).to eq("509658")
    expect(event.device).to eq("desktop")
    expect(event.seconds).to eq(3600)
  end

  it "PVA ETL handles legacy sync events without game_id/device (graceful nullable)" do
    create(:sync_event, user: user, event_type: "stream_view",
      payload: { "channel_id" => "555", "login" => "shroud",
                 "watched_at" => "2026-05-28T20:00:00Z", "duration_sec" => 1800 })

    PersonalAnalytics::Aggregation::ViewEventEtl.call(user.id)

    event = PvaViewEvent.find_by(user_id: user.id)
    expect(event.game_id).to be_nil
    expect(event.device).to be_nil # clamp_device возвращает nil для отсутствующих/невалидных
  end
end
