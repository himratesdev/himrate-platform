# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Viewer discover page", type: :request do
  it "renders the faithful export markup with the wiring bundle (public shell, JS gates on auth)" do
    get "/app/discover"

    expect(response).to have_http_status(:ok)
    expect(response.body).to include('data-pencil-name="Channel Grid"')
    expect(response.body).to include('data-pencil-name="Preview Panel"')
    expect(response.body).to include("landing/discover")
    expect(response.body).to include("landing/brand_nav")
  end

  it "does not shadow the public marketing pages" do
    get "/streamers"
    expect(response).to have_http_status(:ok)
    expect(response.body).not_to include('data-pencil-name="Channel Grid"')
  end
end
