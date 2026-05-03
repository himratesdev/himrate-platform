# frozen_string_literal: true

require "rails_helper"

RSpec.describe Streams::DurationFormatter do
  describe ".format" do
    it "returns nil для nil seconds" do
      expect(described_class.format(seconds: nil)).to be_nil
    end

    it "returns nil для zero/negative seconds" do
      expect(described_class.format(seconds: 0)).to be_nil
      expect(described_class.format(seconds: -10)).to be_nil
    end

    context "RU locale (default)" do
      it "formats 6h12m as '6ч 12м'" do
        expect(described_class.format(seconds: 22_320, locale: :ru)).to eq("6ч 12м")
      end

      it "formats <1h как 'Nмин'" do
        expect(described_class.format(seconds: 1800, locale: :ru)).to eq("30мин")
      end

      it "formats >24h как 'Dд Hч'" do
        expect(described_class.format(seconds: 90_000, locale: :ru)).to eq("1д 1ч")
      end
    end

    context "EN locale" do
      it "formats 6h12m as '6h 12m'" do
        expect(described_class.format(seconds: 22_320, locale: :en)).to eq("6h 12m")
      end

      it "formats <1h как 'N min'" do
        expect(described_class.format(seconds: 1800, locale: :en)).to eq("30 min")
      end

      it "formats >24h как 'Dd Hh'" do
        expect(described_class.format(seconds: 90_000, locale: :en)).to eq("1d 1h")
      end
    end
  end
end
