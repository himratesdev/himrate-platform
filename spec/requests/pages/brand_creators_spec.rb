# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Brand creator discovery page (screen 60)", type: :request do
  it "renders the faithful export markup with the wiring bundle on the app layout (JS gates on auth)" do
    get "/app/creators"

    expect(response).to have_http_status(:ok)
    expect(response.body).to include('data-pencil-name="Results Toolbar"')       # results toolbar
    expect(response.body).to include('data-pencil-name="Fraud Pill"')            # fraud pill (JS hides it)
    expect(response.body).to match(/data-pencil-name="Card · [^"]+"/)            # result-card template
    expect(response.body).to match(%r{landing/brand_creators[-\w]*\.js})         # wiring bundle
    expect(response.body).to match(%r{landing/brand_nav[-\w]*\.js})              # dashboard chrome
    expect(response.body).to match(/<meta name="robots" content="noindex, follow">/) # app layout (product, noindex)
    expect(response.body).not_to match(%r{landing/hr-shared[-\w]*\.js})          # no marketing canvas/nav
  end

  it "does not shadow the public marketing pages" do
    get "/streamers"
    expect(response).to have_http_status(:ok)
    expect(response.body).not_to match(%r{landing/brand_creators[-\w]*\.js})
  end
end
