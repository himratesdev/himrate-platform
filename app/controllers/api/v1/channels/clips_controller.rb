# frozen_string_literal: true

module Api
  module V1
    module Channels
      # Public «clips of a channel» (WEB-CONSOLIDATION): a channel's best clips right now. Like the
      # rest of the card, a fact about the channel — open to guests, no per-user data, and covered
      # by the same general per-IP API budget as every other public channel read.
      class ClipsController < Api::BaseController
        include Channelable

        before_action :authenticate_user_optional!
        before_action :set_channel

        # GET /api/v1/channels/:login/clips?limit=12
        def index
          authorize @channel, :view_clips?

          clips = ::Channels::ClipsQuery.new(channel: @channel, limit: params[:limit]).call
          render json: { data: { login: @channel.login, clips: FarmClipBlueprint.render_as_hash(clips) } }
        end
      end
    end
  end
end
