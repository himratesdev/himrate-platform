# frozen_string_literal: true

class UserMailerPreview < ActionMailer::Preview
  def welcome
    UserMailer.welcome(User.first || FactoryBot.build_stubbed(:user))
  end
end
