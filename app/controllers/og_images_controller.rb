# frozen_string_literal: true

# Dynamic Open Graph share images (TASK-060 Level 2). Public, unauthenticated PNG
# endpoint used as og:image for channel share links. CDN-cached (s-maxage) so crawlers
# and re-shares hit the edge, not the app. Any failure falls back to the static brand
# card — a share preview must never break.
class OgImagesController < ApplicationController
  # GET /og/c/:login.png — per-channel share card.
  def channel
    channel = Channel.find_by(login: params[:login]) ||
              Channel.find_by(login: params[:login].to_s.downcase)
    return redirect_to_default unless channel

    png = Og::ChannelCardImage.new(channel).call
    response.set_header("Cache-Control", "public, max-age=1800, s-maxage=86400")
    send_data png, type: "image/png", disposition: "inline"
  rescue StandardError => e
    Rails.logger.warn("[OgImagesController] channel card failed for #{params[:login]}: #{e.class} #{e.message}")
    redirect_to_default
  end

  private

  def redirect_to_default
    redirect_to ActionController::Base.helpers.asset_path("brand/logo-square-gradient.svg"),
                allow_other_host: false
  end

  # Public rendering endpoint — never 406 a crawler on the modern-browser guard.
  def browser_guard_enabled?
    false
  end
end
