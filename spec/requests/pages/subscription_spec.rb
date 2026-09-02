# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Subscription page (screen 40)", type: :request do
  it "renders the faithful export markup with the wiring bundles (public shell, JS gates on auth)" do
    get "/app/subscription"

    expect(response).to have_http_status(:ok)
    expect(response.body).to include('data-pencil-name="Current Plan Card"')
    expect(response.body).to include('data-pencil-name="Card · Промокод"')
    expect(response.body).to include("landing/subscription")
    expect(response.body).to include("landing/promo-card")
    expect(response.body).to include("landing/brand_nav")
  end

  it "carries no sample billing data (design fakes purged: card, RUB prices, invoices)" do
    get "/app/subscription"

    expect(response.body).not_to include("4242")
    expect(response.body).not_to include("990 ₽")
    expect(response.body).not_to include("Creator Pro")
    expect(response.body).to include("Операций пока нет")
  end

  it "serves the short path on the app host without redirect" do
    get "/subscription", headers: { "HOST" => "app.himrate.com" }
    expect(response).to have_http_status(:ok)
  end
end
