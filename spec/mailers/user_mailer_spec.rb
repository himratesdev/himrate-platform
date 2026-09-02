# frozen_string_literal: true

require "rails_helper"

RSpec.describe UserMailer do
  let(:user) { create(:user, locale: "ru", display_name: "Денис") }

  describe "#welcome" do
    it "renders in the user's locale with both parts" do
      mail = described_class.welcome(user)
      expect(mail.to).to eq([ user.email ])
      expect(mail.subject).to eq("Добро пожаловать в HimRate")
      expect(mail.text_part.body.to_s).to include("Денис").and include("himrate.com")
      expect(mail.html_part.body.to_s).to include("app.himrate.com/home")
    end

    it "uses the DB-default locale (en) when the user never chose one" do
      # users.locale is NOT NULL DEFAULT 'en' — a locale-less row is impossible; the
      # `presence ||` guard in the mailer covers only a hypothetical blank string.
      mail = described_class.welcome(create(:user))
      expect(mail.subject).to eq("Welcome to HimRate")
    end
  end

  describe "registered lifecycle hook" do
    it "enqueues the welcome mail on user creation (after_create_commit)" do
      expect { create(:user) }.to have_enqueued_mail(described_class, :welcome)
    end
  end
end
