# frozen_string_literal: true

require "rails_helper"

RSpec.describe PersonalAnalytics::RussianPlural do
  describe ".key" do
    it "returns :one for n mod10 == 1 except n mod100 == 11" do
      expect(described_class.key(1)).to eq(:one)
      expect(described_class.key(21)).to eq(:one)
      expect(described_class.key(101)).to eq(:one)
      expect(described_class.key(11)).to eq(:many) # not :one
      expect(described_class.key(111)).to eq(:many)
    end

    it "returns :few for n mod10 ∈ [2,3,4] except n mod100 ∈ [12,13,14]" do
      expect(described_class.key(2)).to eq(:few)
      expect(described_class.key(3)).to eq(:few)
      expect(described_class.key(4)).to eq(:few)
      expect(described_class.key(22)).to eq(:few)
      expect(described_class.key(104)).to eq(:few)
      expect(described_class.key(12)).to eq(:many) # not :few
      expect(described_class.key(13)).to eq(:many)
      expect(described_class.key(14)).to eq(:many)
    end

    it "returns :many for the rest (0, 5-20, 25-30, …)" do
      expect(described_class.key(0)).to eq(:many)
      expect(described_class.key(5)).to eq(:many)
      expect(described_class.key(20)).to eq(:many)
      expect(described_class.key(100)).to eq(:many)
    end
  end

  describe ".translate" do
    it "selects the correct form for Russian locale" do
      I18n.with_locale(:ru) do
        expect(described_class.translate("pva.sessions_form", count: 1)).to eq("1 сессию")
        expect(described_class.translate("pva.sessions_form", count: 4)).to eq("4 сессии")
        expect(described_class.translate("pva.sessions_form", count: 5)).to eq("5 сессий")
        expect(described_class.translate("pva.sessions_form", count: 21)).to eq("21 сессию")
      end
    end

    it "falls back to count.to_s when the scope is missing" do
      expect(described_class.translate("pva.does.not.exist", count: 3)).to eq("3")
    end
  end
end
