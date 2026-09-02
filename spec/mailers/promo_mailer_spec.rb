# frozen_string_literal: true

require "rails_helper"

RSpec.describe PromoMailer do
  let(:user) { create(:user, locale: "en", username: "tester") }

  describe "#activated" do
    it "names the tier and the expiry date" do
      mail = described_class.activated(user, tier: "premium", expires_at: Time.zone.parse("2026-10-01 12:00"))
      expect(mail.subject).to eq("Promo code activated")
      expect(mail.text_part.body.to_s).to include("premium").and include("2026")
    end

    it "renders the lifetime variant when there is no expiry" do
      mail = described_class.activated(user, tier: "business", expires_at: nil)
      expect(mail.text_part.body.to_s).to include("no expiry")
    end
  end
end
