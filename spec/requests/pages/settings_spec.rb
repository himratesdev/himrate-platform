# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Viewer settings page", type: :request do
  it "renders the faithful export markup with the wiring bundle (public shell, JS gates on auth)" do
    get "/app/settings"

    expect(response).to have_http_status(:ok)
    expect(response.body).to include('data-pencil-name="Card · Приватность"')
    expect(response.body).to include('data-pencil-name="Acc · Twitch"')
    # the client-side wiring bundle + shared dashboard nav are loaded
    expect(response.body).to include("landing/settings")
    expect(response.body).to include("landing/brand_nav")
    expect(response.body).to include("landing/hr-i18n")
  end

  it "does not shadow the public marketing pages" do
    get "/streamers"
    expect(response).to have_http_status(:ok)
    expect(response.body).not_to include('data-pencil-name="Card · Приватность"')
  end
end
