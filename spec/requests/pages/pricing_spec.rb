# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Pricing page", type: :request do
  it "renders the canon-priced faithful export with the wiring bundle" do
    get "/pricing"

    expect(response).to have_http_status(:ok)
    expect(response.body).to include('data-pencil-name="Screen · Тарифы"')
    # streamer/viewer side — canon PRICING v4.2
    expect(response.body).to include("$9.99")
    expect(response.body).to include('data-plan="premium"')
    # brand ladder starts at $299 (the design's invented $99 Starter is gone)
    expect(response.body).to include("далее $499")
    expect(response.body).not_to include("Для небольших брендов и соло-маркетологов")
    # annual discount is the canonical −16, not the design's −20
    expect(response.body).to include("Год · −16%")
    expect(response.body).not_to include("−20%")
    # the client-side wiring bundle + shared i18n are loaded
    expect(response.body).to include("landing/pricing")
    expect(response.body).to include("landing/hr-i18n")
  end

  it "is indexable (marketing layout, no noindex)" do
    get "/pricing"
    expect(response.body).not_to include("noindex")
  end

  it "bounces the app host to the apex (marketing surface)" do
    get "/pricing", headers: { "HOST" => "app.himrate.com" }
    expect(response).to have_http_status(:moved_permanently)
    expect(response.headers["Location"]).to eq("https://himrate.com/pricing")
  end
end
