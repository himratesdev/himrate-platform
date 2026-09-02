# frozen_string_literal: true

# External-integration lane (4.3): REAL anonymous Twitch IRC over TLS (the justinfan path
# bin/irc_monitor rides). Raw socket — WebMock does not apply. No credentials required.
require "rails_helper"
require_relative "live_channel_helper"
require "socket"
require "openssl"

RSpec.describe "Twitch IRC anonymous (real connection)", :external, type: :integration do
  it "connects, joins a live channel and receives chat traffic within 30s" do
    login = ExternalLiveChannel.pick
    skip "no live channel resolvable" if login.nil?

    tcp = TCPSocket.new(Twitch::IrcMonitor::IRC_HOST, Twitch::IrcMonitor::IRC_PORT)
    ctx = OpenSSL::SSL::SSLContext.new
    ssl = OpenSSL::SSL::SSLSocket.new(tcp, ctx)
    ssl.hostname = Twitch::IrcMonitor::IRC_HOST
    ssl.connect
    # ROOMSTATE only arrives with the commands/tags capability — same caps bin/irc_monitor requests.
    ssl.write("CAP REQ :twitch.tv/commands twitch.tv/tags\r\n")
    ssl.write("NICK justinfan#{rand(10_000..99_999)}\r\n")
    ssl.write("JOIN ##{login}\r\n")

    seen = []
    deadline = Time.now + 30
    while Time.now < deadline
      ready = IO.select([ ssl ], nil, nil, deadline - Time.now)
      break unless ready

      line = ssl.gets
      break if line.nil?

      seen << line
      ssl.write("PONG :tmi.twitch.tv\r\n") if line.start_with?("PING")
      break if line.include?("PRIVMSG") || line.include?("ROOMSTATE")
    end
    ssl.close rescue nil

    expect(seen.join).to match(/PRIVMSG|ROOMSTATE/),
      "no PRIVMSG/ROOMSTATE from ##{login} in 30s; got:\n#{seen.last(10).join}"
  end
end
