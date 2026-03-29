# frozen_string_literal: true

require "rails_helper"

# TASK-024: Real integration test for Twitch IRC.
# Connects to real irc.chat.twitch.tv:6697 as justinfan.
# Run manually: bundle exec rspec spec/services/twitch/irc_monitor_real_spec.rb --tag irc_real
# NOT run in CI (requires internet + Twitch availability).

RSpec.describe "Twitch IRC Real Integration", irc_real: true do
  let(:host) { "irc.chat.twitch.tv" }
  let(:port) { 6697 }
  let(:parser) { Twitch::IrcParser.new }

  # Helper: connect raw TLS socket to Twitch IRC
  def connect_irc
    tcp = TCPSocket.new(host, port)
    ctx = OpenSSL::SSL::SSLContext.new
    ctx.min_version = OpenSSL::SSL::TLS1_2_VERSION
    ctx.verify_mode = OpenSSL::SSL::VERIFY_PEER
    ctx.cert_store = OpenSSL::X509::Store.new.tap(&:set_default_paths)

    ssl = OpenSSL::SSL::SSLSocket.new(tcp, ctx)
    ssl.hostname = host
    ssl.connect

    ssl.write("CAP REQ :twitch.tv/tags twitch.tv/commands\r\n")
    ssl.write("PASS SCHMOOPIIE\r\n")
    ssl.write("NICK justinfan#{rand(1000..9999)}\r\n")

    # Wait for MOTD
    10.times do
      line = ssl.gets
      break if line&.include?("376") || line&.include?("Welcome")
    end

    [ tcp, ssl ]
  end

  # TC-001: Real TLS connection + justinfan auth
  it "connects to Twitch IRC via TLS as justinfan" do
    tcp, ssl = connect_irc

    expect(ssl).not_to be_closed

    ssl.close
    tcp.close
  end

  # TC-002 (real): Parse real PRIVMSG from live channel
  it "receives and parses real PRIVMSG from a live channel" do
    tcp, ssl = connect_irc

    # Join a popular channel that's usually active
    ssl.write("JOIN #xqc\r\n")

    # Wait for messages (up to 30 seconds)
    messages = []
    deadline = Time.current + 30

    while Time.current < deadline && messages.size < 3
      if IO.select([ tcp ], nil, nil, 1)
        line = ssl.gets
        next unless line

        parsed = parser.parse(line)
        if parsed && parsed.command == "PRIVMSG"
          messages << parsed
        end
      end
    end

    ssl.write("PART #xqc\r\n")
    ssl.close
    tcp.close

    if messages.any?
      msg = messages.first
      expect(msg.channel_login).to eq("xqc")
      expect(msg.username).to be_present
      expect(msg.message_text).to be_present
      expect(msg.tags).to be_a(Hash)
      expect(msg.tags).to have_key("display-name")

      # Verify to_record produces valid insert data
      record = parser.to_record(msg)
      expect(record[:channel_login]).to eq("xqc")
      expect(record[:username]).to be_present
      expect(record[:msg_type]).to eq("privmsg")
      expect(record[:raw_tags]).to be_a(Hash)
    else
      # Channel might be offline or quiet — not a failure
      pending "No PRIVMSG received in 30s (channel may be offline)"
    end
  end

  # TC-006 (real): Parse real ROOMSTATE
  it "receives ROOMSTATE on JOIN" do
    tcp, ssl = connect_irc

    ssl.write("JOIN #xqc\r\n")

    roomstate = nil
    deadline = Time.current + 10

    while Time.current < deadline && roomstate.nil?
      if IO.select([ tcp ], nil, nil, 1)
        line = ssl.gets
        next unless line

        parsed = parser.parse(line)
        roomstate = parsed if parsed&.command == "ROOMSTATE"
      end
    end

    ssl.close
    tcp.close

    if roomstate
      expect(roomstate.msg_type).to eq("roomstate")
      expect(roomstate.channel_login).to eq("xqc")
      # ROOMSTATE always has these keys
      expect(roomstate.tags).to include("followers-only")
    else
      pending "No ROOMSTATE received (unusual but possible)"
    end
  end

  # TC-015 (real): PING/PONG
  it "can send PING and receive PONG" do
    tcp, ssl = connect_irc

    ssl.write("PING :himrate-test\r\n")

    pong_received = false
    deadline = Time.current + 10

    while Time.current < deadline && !pong_received
      if IO.select([ tcp ], nil, nil, 1)
        line = ssl.gets
        pong_received = true if line&.include?("PONG")
      end
    end

    ssl.close
    tcp.close

    expect(pong_received).to be true
  end
end
