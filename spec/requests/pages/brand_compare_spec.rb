# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Brand compare page", type: :request do
  it "renders the faithful export markup with the wiring bundle (public shell, JS gates on auth)" do
    get "/app/compare"

    expect(response).to have_http_status(:ok)
    expect(response.body).to include('data-pencil-name="Compare Table"')
    expect(response.body).to include('data-pencil-name="Recommendation"')
    # the client-side wiring bundle is loaded
    expect(response.body).to include("landing/brand_compare")
    # shared layout (Tailwind + fonts + i18n)
    expect(response.body).to include("landing/hr-i18n")
  end

  it "does not shadow the public marketing pages" do
    get "/streamers"
    expect(response).to have_http_status(:ok)
    expect(response.body).not_to include('data-pencil-name="Compare Table"')
  end
end
