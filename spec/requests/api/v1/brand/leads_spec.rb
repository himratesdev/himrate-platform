# frozen_string_literal: true

require "rails_helper"

# W1: public B2B lead capture (/brands contact form → real engine).
RSpec.describe "Brand leads API" do
  describe "POST /api/v1/brand/leads" do
    let(:valid) { { name: "Иван", email: "ivan@corp.ru", company: "Corp", budget: "$5k", message: "Хотим кампанию" } }

    it "persists a lead and notifies telegram (201, guest-open)" do
      allow(TelegramAlertWorker).to receive(:perform_async)

      expect { post "/api/v1/brand/leads", params: valid }.to change(BrandLead, :count).by(1)

      expect(response).to have_http_status(:created)
      lead = BrandLead.last
      expect(lead).to have_attributes(name: "Иван", email: "ivan@corp.ru", company: "Corp",
                                      status: "new", source_page: "/brands")
      expect(TelegramAlertWorker).to have_received(:perform_async).with(a_string_including("ivan@corp.ru"))
    end

    it "honeypot: a filled website field gets a happy 201 with NO record" do
      expect { post "/api/v1/brand/leads", params: valid.merge(website: "http://spam.bot") }
        .not_to change(BrandLead, :count)
      expect(response).to have_http_status(:created)
    end

    it "422 with details on a bad email / missing name" do
      post "/api/v1/brand/leads", params: { name: "", email: "not-an-email" }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body.dig("error", "code")).to eq("VALIDATION_ERROR")
      expect(response.parsed_body.dig("error", "details")).to be_present
    end

    it "normalizes the email and trims strings" do
      post "/api/v1/brand/leads", params: valid.merge(email: "  IVAN@Corp.RU ", name: "  Иван  ")
      expect(BrandLead.last.email).to eq("ivan@corp.ru")
      expect(BrandLead.last.name).to eq("Иван")
    end

    it "a telegram failure never loses the lead" do
      allow(TelegramAlertWorker).to receive(:perform_async).and_raise(StandardError, "redis down")
      expect { post "/api/v1/brand/leads", params: valid }.to change(BrandLead, :count).by(1)
      expect(response).to have_http_status(:created)
    end
  end
end
