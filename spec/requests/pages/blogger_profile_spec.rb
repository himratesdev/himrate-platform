# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Brand blogger profile page (screen 61)", type: :request do
  it "renders the faithful export markup with the wiring bundle on the app layout (JS gates on auth)" do
    get "/app/blogger/recrent"

    expect(response).to have_http_status(:ok)
    expect(response.body).to include('data-pencil-name="Card Публикации"')         # descriptive publications
    expect(response.body).to include('data-pencil-name="Card Связанные аккаунты"') # cross-platform footprint
    expect(response.body).to include('data-pencil-name="Card Доверие"')            # fraud card (JS hides it)
    expect(response.body).to match(%r{landing/blogger_profile[-\w]*\.js})          # wiring bundle
    expect(response.body).to match(%r{landing/brand_nav[-\w]*\.js})                # dashboard chrome
    expect(response.body).to match(/<meta name="robots" content="noindex, follow">/) # app layout (product, noindex)
    expect(response.body).not_to match(%r{landing/hr-shared[-\w]*\.js})            # no marketing canvas/nav
  end

  it "does not shadow the public marketing pages" do
    get "/streamers"
    expect(response).to have_http_status(:ok)
    expect(response.body).not_to match(%r{landing/blogger_profile[-\w]*\.js})
  end
end
