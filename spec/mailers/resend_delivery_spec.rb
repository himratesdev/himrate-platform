# frozen_string_literal: true

require "rails_helper"
require "resend/mailer"

# CR iter-1 SF-3: the provider path itself had zero coverage — both mailer specs render through
# delivery_method :test, so Resend::Mailer#build_resend_params (the multipart → text/html mapping
# and the `from` extraction) never executed. A live send stays a post-deploy verification step;
# this covers everything up to the HTTP call.
RSpec.describe "Resend delivery path" do
  let(:user) { create(:user, email: "po@example.com", locale: "ru", username: "po") }

  it "registers :resend as an ActionMailer delivery method (gem railtie)" do
    expect(ActionMailer::Base.delivery_methods).to include(:resend)
    expect(ActionMailer::Base.delivery_methods[:resend]).to eq(Resend::Mailer)
  end

  it "refuses to build a mailer without the gem-global api key (why config assigns it first)" do
    original = Resend.api_key
    Resend.api_key = nil
    expect { Resend::Mailer.new({}) }.to raise_error(Resend::Error)
  ensure
    Resend.api_key = original
  end

  describe "payload mapping" do
    around do |example|
      original = Resend.api_key
      Resend.api_key = "re_test_key"
      example.run
      Resend.api_key = original
    end

    it "maps a multipart mail to Resend's from/to/subject/text/html params" do
      mail = PromoMailer.activated(user, tier: "premium", expires_at: Time.zone.parse("2026-10-01 12:00"))
      params = Resend::Mailer.new({}).build_resend_params(mail)

      expect(params[:from]).to eq(ENV.fetch("MAIL_FROM", "HimRate <noreply@himrate.com>"))
      expect(params[:to]).to eq([ "po@example.com" ])
      expect(params[:subject]).to eq("Промокод активирован")
      # multipart/alternative → both parts must survive; a text-only payload was the silent-drop risk.
      expect(params[:text]).to include("Premium")
      expect(params[:html]).to include("Premium")
    end
  end
end
