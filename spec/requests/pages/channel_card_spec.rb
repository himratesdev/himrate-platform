# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Public channel card page", type: :request do
  it "renders the faithful export markup for a public visitor (no auth)" do
    create(:channel, login: "buster") # a known channel — unknown logins 404 (no soft-404 SEO junk)
    get "/c/buster"

    expect(response).to have_http_status(:ok)
    # faithful Pencil-export anchors are present (real data is wired client-side)
    expect(response.body).to include('data-pencil-name="L1 Real"')
    expect(response.body).to include('data-pencil-name="L1 Rep T"')
    # the client-side wiring bundle is loaded
    expect(response.body).to include("landing/channel_card")
    # public marketing layout (shared with the landing)
    expect(response.body).to include("landing/hr-i18n")
  end

  it "does not shadow the marketing pages (distinct /c/ prefix)" do
    get "/streamers"
    expect(response).to have_http_status(:ok)
    expect(response.body).not_to include('data-pencil-name="L1 Real"') # streamers page, not the card
  end
end
