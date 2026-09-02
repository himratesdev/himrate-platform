# frozen_string_literal: true

require "rails_helper"

RSpec.describe PromoMailer do
  let(:user) { create(:user, locale: "en", username: "tester") }

  describe "#activated" do
    it "names the tier and the expiry date" do
      mail = described_class.activated(user, tier: "premium", expires_at: Time.zone.parse("2026-10-01 12:00"))
      expect(mail.subject).to eq("Promo code activated")
      expect(mail.text_part.body.to_s).to include("Premium").and include("2026")
    end

    it "renders the lifetime variant when there is no expiry" do
      mail = described_class.activated(user, tier: "business", expires_at: nil)
      expect(mail.text_part.body.to_s).to include("no expiry")
    end

    # CR iter-1 Nit-8 + Nit-5: the ru render was uncovered, and the expiry date used to fall back to
    # the en ISO format ("2026-10-01") — config/locales/date.ru.yml (P6 CR iter-1) fixes the format,
    # this pins it so a locale-file regression is caught here.
    context "in Russian" do
      let(:user) { create(:user, locale: "ru", username: "tester") }

      it "renders cyrillic copy, the dd.mm.yyyy date and the brand plan name" do
        mail = described_class.activated(user, tier: "premium", expires_at: Time.zone.parse("2026-10-01 12:00"))

        expect(mail.subject).to eq("Промокод активирован")
        body = mail.text_part.body.to_s
        expect(body).to include("Доступ уровня «Premium» активирован до 01.10.2026")
        expect(body).not_to include("2026-10-01") # no ISO fallback
        expect(body).not_to include("«premium»")  # no raw enum
      end
    end
  end
end
