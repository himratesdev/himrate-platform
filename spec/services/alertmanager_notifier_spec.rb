# frozen_string_literal: true

require "rails_helper"

RSpec.describe AlertmanagerNotifier do
  let(:url) { "http://himrate-alertmanager:9093/api/v2/alerts" }
  let(:labels) { { alertname: "Foo", severity: "critical" } }
  let(:annotations) { { summary: "Bar", description: "details" } }

  before do
    # PR-B2 CR iter-2: `ALERTMANAGER_URL` is frozen at boot. PR-B2 default state is
    # blank (observability disabled → straight Telegram routing). Stub the constant
    # to simulate the env var being set for live-path specs. The new "disabled" describe
    # block below exercises the blank/disabled fallback path.
    stub_const("AlertmanagerNotifier::ALERTMANAGER_URL", url)
    allow(described_class).to receive(:sleep) # avoid real backoff sleeps в specs
  end

  describe ".push" do
    it "returns :ok при successful POST" do
      stub_request(:post, url).to_return(status: 200)
      expect(described_class.push(labels: labels, annotations: annotations)).to eq(:ok)
    end

    it "retries 3 раза затем falls back на Telegram" do
      stub_request(:post, url).to_return(status: 500).times(3)
      stub_request(:post, /api.telegram.org/).to_return(status: 200)
      allow(ENV).to receive(:[]).with("TELEGRAM_OPS_BOT_TOKEN").and_return("bot_tok")
      allow(ENV).to receive(:[]).with("TELEGRAM_CRITICAL_CHAT_ID").and_return("12345")

      result = described_class.push(labels: labels, annotations: annotations)
      expect(result).to eq(:fallback)
      expect(WebMock).to have_requested(:post, url).times(3)
    end

    it "returns :degraded когда Telegram secrets missing" do
      stub_request(:post, url).to_return(status: 500).times(3)
      allow(ENV).to receive(:[]).with("TELEGRAM_OPS_BOT_TOKEN").and_return(nil)
      allow(ENV).to receive(:[]).with("TELEGRAM_CRITICAL_CHAT_ID").and_return(nil)

      expect(described_class.push(labels: labels, annotations: annotations)).to eq(:degraded)
    end

    it "returns :ok сразу без retries при первом успехе" do
      stub_request(:post, url).to_return(status: 200)
      described_class.push(labels: labels, annotations: annotations)
      expect(WebMock).to have_requested(:post, url).once
    end

    it "обрабатывает Alertmanager unreachable (raises) → fallback" do
      stub_request(:post, url).to_raise(Errno::ECONNREFUSED.new("blocked"))
      stub_request(:post, /api.telegram.org/).to_return(status: 200)
      allow(ENV).to receive(:[]).with("TELEGRAM_OPS_BOT_TOKEN").and_return("bot_tok")
      allow(ENV).to receive(:[]).with("TELEGRAM_CRITICAL_CHAT_ID").and_return("12345")

      expect(described_class.push(labels: labels, annotations: annotations)).to eq(:fallback)
    end

    it "payload contains labels + annotations as strings" do
      stub_request(:post, url).to_return(status: 200)
      described_class.push(labels: labels, annotations: annotations)
      expect(WebMock).to have_requested(:post, url).with { |req|
        body = JSON.parse(req.body)
        body.first["labels"]["alertname"] == "Foo" && body.first["annotations"]["summary"] == "Bar"
      }
    end
  end

  describe "RETRY_DELAYS" do
    it "uses exponential schedule [2, 4, 8]" do
      expect(described_class::RETRY_DELAYS).to eq([ 2, 4, 8 ])
    end
  end

  # PR-B2 CR iter-2: when observability accessories disabled (ALERTMANAGER_URL blank),
  # route alerts straight to Telegram without burning the 2+4+8s retry-sleep cycle
  # against the removed himrate-alertmanager accessory.
  describe "when disabled (ALERTMANAGER_URL blank — PR-B2 default state)" do
    before { stub_const("AlertmanagerNotifier::ALERTMANAGER_URL", "") }

    it "routes alert directly to Telegram fallback, no Alertmanager request" do
      stub_request(:post, /api.telegram.org/).to_return(status: 200)
      allow(ENV).to receive(:[]).with("TELEGRAM_OPS_BOT_TOKEN").and_return("bot_tok")
      allow(ENV).to receive(:[]).with("TELEGRAM_CRITICAL_CHAT_ID").and_return("12345")

      result = described_class.push(labels: labels, annotations: annotations)
      expect(result).to eq(:fallback)
      expect(WebMock).not_to have_requested(:post, /himrate-alertmanager/)
      expect(WebMock).to have_requested(:post, /api.telegram.org/)
    end

    it "returns :degraded когда disabled + Telegram secrets missing" do
      allow(ENV).to receive(:[]).with("TELEGRAM_OPS_BOT_TOKEN").and_return(nil)
      allow(ENV).to receive(:[]).with("TELEGRAM_CRITICAL_CHAT_ID").and_return(nil)

      expect(described_class.push(labels: labels, annotations: annotations)).to eq(:degraded)
      expect(WebMock).not_to have_requested(:post, /himrate-alertmanager/)
    end
  end
end
