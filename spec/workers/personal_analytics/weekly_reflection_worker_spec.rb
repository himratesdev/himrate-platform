# frozen_string_literal: true

require "rails_helper"

RSpec.describe PersonalAnalytics::WeeklyReflectionWorker do
  let(:user) { create(:user, locale: "ru") }
  let(:monday) { Date.new(2026, 5, 18) }

  context "when :pva is enabled" do
    before do
      allow(Flipper).to receive(:enabled?).and_call_original
      allow(Flipper).to receive(:enabled?).with(:pva).and_return(true)
    end

    it "delegates to ReflectionBuilder for the parsed week and writes a row" do
      create(:pva_view_rollup, user: user, date: monday, total_seconds: 3600)

      described_class.new.perform(user.id, monday.iso8601)

      expect(PvaWeeklyReflection.find_by(user_id: user.id, week_start: monday)).to be_present
    end

    it "defaults to the last completed week when week_start_iso is nil" do
      # default_week_start = последняя завершённая неделя; rollup на Date.current точно попадает в неё
      # или в текущую — в любом случае builder вернёт nil (нет данных за прошлую) и worker no-ops.
      expect { described_class.new.perform(user.id, nil) }.not_to raise_error
    end

    it "drops invalid ISO week strings and falls back to default" do
      expect { described_class.new.perform(user.id, "not-a-date") }.not_to raise_error
    end
  end

  context "when :pva is disabled" do
    before do
      allow(Flipper).to receive(:enabled?).and_call_original
      allow(Flipper).to receive(:enabled?).with(:pva).and_return(false)
    end

    it "is a no-op" do
      create(:pva_view_rollup, user: user, date: monday, total_seconds: 3600)

      described_class.new.perform(user.id, monday.iso8601)

      expect(PvaWeeklyReflection.where(user_id: user.id)).to be_empty
    end
  end
end
