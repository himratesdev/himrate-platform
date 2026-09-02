# frozen_string_literal: true

# External-integration lane (4.3): REAL anonymous Twitch IRC over TLS (the justinfan path
# bin/irc_monitor rides). Raw socket — WebMock does not apply. No credentials required.
require "rails_helper"
require_relative "live_channel_helper"
require "socket"
require "openssl"

RSpec.describe "Twitch IRC anonymous (real connection)", :external, type: :integration do
  # `let`, not a constant: a constant assigned inside a describe block lands on Object and would
  # shadow bare `WINDOW` lookups suite-wide (Reputation::BandService::WINDOW already exists).
  let(:window) { 30 } # seconds

  it "connects, joins a live channel and receives chat traffic within 30s" do
    login = ExternalLiveChannel.pick
    skip "no live channel resolvable" if login.nil?

    tcp = nil
    ssl = nil
    seen = []
    begin
      tcp = TCPSocket.new(Twitch::IrcMonitor::IRC_HOST, Twitch::IrcMonitor::IRC_PORT)
      ctx = OpenSSL::SSL::SSLContext.new
      ssl = OpenSSL::SSL::SSLSocket.new(tcp, ctx)
      ssl.hostname = Twitch::IrcMonitor::IRC_HOST
      ssl.connect
      # ROOMSTATE only arrives with the commands/tags capability — same caps bin/irc_monitor requests.
      ssl.write("CAP REQ :twitch.tv/commands twitch.tv/tags\r\n")
      ssl.write("NICK justinfan#{rand(10_000..99_999)}\r\n")
      ssl.write("JOIN ##{login}\r\n")

      # Monotonic deadline: Time.now can jump (NTP/suspend) and the previous `deadline - Time.now`
      # could go negative between the loop check and the select call → ArgumentError instead of an
      # honest timeout. `gets` also blocks with no read timeout once select reports a partial line,
      # so the read timeout is set on the socket itself.
      ssl.timeout = 5 if ssl.respond_to?(:timeout=)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + window
      loop do
        remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
        break if remaining <= 0
        break unless IO.select([ ssl ], nil, nil, [ remaining, 0 ].max)

        # A read timeout means "quiet channel / partial line", not "give up": the contract is the
        # `window`-second budget, so keep looping and let the deadline check above end the run.
        # Only a dead connection (EOF / TLS error) is terminal.
        begin
          line = ssl.gets
        rescue IO::TimeoutError
          next
        rescue OpenSSL::SSL::SSLError
          break
        end
        break if line.nil?

        seen << line
        ssl.write("PONG :tmi.twitch.tv\r\n") if line.start_with?("PING")
        break if line.include?("PRIVMSG") || line.include?("ROOMSTATE")
      end
    ensure
      # Closing a half-open TLS socket must not mask the assertion below.
      begin
        ssl&.close
        tcp&.close
      rescue IOError, OpenSSL::SSL::SSLError
        nil
      end
    end

    expect(seen.join).to match(/PRIVMSG|ROOMSTATE/),
      "no PRIVMSG/ROOMSTATE from ##{login} within #{window}s; last lines:\n#{seen.last(10).join}"
  end
end
