# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Brand streamer search page", type: :request do
  it "renders the faithful export markup with the wiring bundle (public shell, JS gates on auth)" do
    get "/app/search"

    expect(response).to have_http_status(:ok)
    # faithful Pencil-export anchors are present (real data + auth gate wired client-side)
    expect(response.body).to include('data-pencil-name="Screen · Поиск стримеров"')
    expect(response.body).to include('data-pencil-name="RT Count"')
    expect(response.body).to include('data-pencil-name="Grid Row"')
    # the client-side wiring bundle is loaded
    expect(response.body).to include("landing/brand_search")
    # shared marketing/dashboard layout (Tailwind + fonts + i18n)
    expect(response.body).to include("landing/hr-i18n")
  end

  it "does not shadow the public marketing pages" do
    get "/streamers"
    expect(response).to have_http_status(:ok)
    expect(response.body).not_to include('data-pencil-name="Screen · Поиск стримеров"')
  end
end
