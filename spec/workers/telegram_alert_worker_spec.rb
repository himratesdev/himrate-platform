# frozen_string_literal: true

require "rails_helper"

RSpec.describe TelegramAlertWorker do
  before do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("TELEGRAM_BOT_TOKEN").and_return("test-token")
    allow(ENV).to receive(:[]).with("TELEGRAM_ALERT_CHAT_ID").and_return("12345")
  end

  describe "#perform" do
    it "sends message to Telegram Bot API" do
      stub_request(:post, "https://api.telegram.org/bottest-token/sendMessage")
        .to_return(status: 200, body: '{"ok":true}')

      described_class.new.perform("Test alert message")

      expect(WebMock).to have_requested(:post, "https://api.telegram.org/bottest-token/sendMessage")
        .with(body: hash_including("chat_id" => "12345", "text" => "Test alert message"))
    end

    it "raises on non-success HTTP (triggers Sidekiq retry)" do
      stub_request(:post, "https://api.telegram.org/bottest-token/sendMessage")
        .to_return(status: 500, body: '{"ok":false}')

      expect { described_class.new.perform("Test") }.to raise_error(RuntimeError, /Telegram API HTTP 500/)
    end

    it "raises on 429 rate limit (triggers Sidekiq retry with backoff)" do
      stub_request(:post, "https://api.telegram.org/bottest-token/sendMessage")
        .to_return(status: 429, body: '{"ok":false}')

      expect { described_class.new.perform("Test") }.to raise_error(RuntimeError, /Telegram API HTTP 429/)
    end

    it "skips when TELEGRAM_BOT_TOKEN not set" do
      allow(ENV).to receive(:[]).with("TELEGRAM_BOT_TOKEN").and_return(nil)

      expect { described_class.new.perform("Test") }.not_to raise_error
      expect(WebMock).not_to have_requested(:post, /api.telegram.org/)
    end
  end
end
