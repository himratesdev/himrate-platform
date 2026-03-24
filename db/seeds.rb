# frozen_string_literal: true

# Seed data for development/test (FR-008 → US-003)

user = User.find_or_create_by!(email: "dev@himrate.com") do |u|
  u.username = "dev_user"
  u.role = "viewer"
  u.tier = "free"
end

channel = Channel.find_or_create_by!(twitch_id: "12345678") do |c|
  c.login = "test_streamer"
  c.display_name = "Test Streamer"
  c.broadcaster_type = "partner"
  c.is_monitored = true
end

Stream.find_or_create_by!(channel: channel, started_at: 1.hour.ago) do |s|
  s.title = "Test Stream"
  s.game_name = "Just Chatting"
  s.language = "en"
end

puts "Seed complete: 1 user, 1 channel, 1 stream"
