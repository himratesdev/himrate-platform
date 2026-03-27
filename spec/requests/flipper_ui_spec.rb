# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Flipper UI", type: :request do
  # TC-007: /admin/flipper without auth → 401
  it "returns 401 without credentials" do
    get "/admin/flipper"
    expect(response).to have_http_status(:unauthorized)
  end

  # TC-008: /admin/flipper with valid auth → success
  it "returns success with valid credentials" do
    credentials = ActionController::HttpAuthentication::Basic.encode_credentials("admin", "dev")
    get "/admin/flipper", headers: { "HTTP_AUTHORIZATION" => credentials }
    expect(response.status).to be_in([ 200, 302 ])
  end

  it "returns 401 with wrong password" do
    credentials = ActionController::HttpAuthentication::Basic.encode_credentials("admin", "wrong")
    get "/admin/flipper", headers: { "HTTP_AUTHORIZATION" => credentials }
    expect(response).to have_http_status(:unauthorized)
  end
end
