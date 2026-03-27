# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Content Security Policy", type: :request do
  describe "GET /health" do
    it "includes CSP header (report-only mode)" do
      get "/health"

      csp_header = response.headers["Content-Security-Policy-Report-Only"] ||
                   response.headers["Content-Security-Policy"]

      expect(csp_header).to be_present
      expect(csp_header).to include("default-src 'self'")
      expect(csp_header).to include("frame-ancestors 'none'")
    end
  end
end
