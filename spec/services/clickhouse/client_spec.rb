# frozen_string_literal: true

require "rails_helper"

# Two layers (project rule: mocked unit + real integration):
#   • Unit — point the client at a non-localhost host so WebMock intercepts; assert request shaping
#     (auth/database headers, JSONEachRow body, FORMAT JSON, error + retry handling).
#   • Integration (:clickhouse) — hit the real CH server (the CI `clickhouse` service on localhost,
#     which WebMock allows via allow_localhost: true). Skips when CH is unreachable (local dev).
RSpec.describe Clickhouse::Client do
  describe "request shaping (unit)" do
    let(:client) do
      described_class.new(host: "clickhouse.test", port: "8123",
                          database: "himrate_test", user: "default", password: "secret")
    end
    let(:url) { "http://clickhouse.test:8123/" }
    let(:auth_headers) do
      { "X-ClickHouse-User" => "default", "X-ClickHouse-Key" => "secret", "X-ClickHouse-Database" => "himrate_test" }
    end

    describe "#execute" do
      it "POSTs the raw SQL with auth + database headers and returns true" do
        stub = stub_request(:post, url)
               .with(body: "CREATE TABLE x (a UInt8) ENGINE = Memory", headers: auth_headers)
               .to_return(status: 200, body: "")

        expect(client.execute("CREATE TABLE x (a UInt8) ENGINE = Memory")).to be(true)
        expect(stub).to have_been_requested
      end

      it "raises QueryError with the CH error text on a 4xx (no retry)" do
        stub = stub_request(:post, url).to_return(status: 404, body: "Code: 60. Unknown table")

        expect { client.execute("SELECT * FROM nope") }.to raise_error(Clickhouse::QueryError, /Code: 60/)
        expect(stub).to have_been_requested.once
      end
    end

    describe "#select" do
      it "appends FORMAT JSON and returns the data array" do
        stub_request(:post, url)
          .with(body: "SELECT 1 AS ok FORMAT JSON")
          .to_return(status: 200, body: { meta: [], data: [ { "ok" => 1 } ] }.to_json)

        expect(client.select("SELECT 1 AS ok")).to eq([ { "ok" => 1 } ])
      end

      it "strips a trailing semicolon before appending FORMAT" do
        stub = stub_request(:post, url).with(body: "SELECT 1 FORMAT JSON").to_return(status: 200, body: { data: [] }.to_json)

        client.select("SELECT 1;")
        expect(stub).to have_been_requested
      end

      it "raises QueryError on a malformed JSON response" do
        stub_request(:post, url).to_return(status: 200, body: "not json")
        expect { client.select("SELECT 1") }.to raise_error(Clickhouse::QueryError, /invalid JSON/)
      end
    end

    describe "#insert" do
      it "builds an INSERT ... FORMAT JSONEachRow body, one JSON object per line" do
        rows = [ { channel_login: "a", username: "u1" }, { channel_login: "b", username: "u2" } ]
        expected = "INSERT INTO chat_messages FORMAT JSONEachRow\n" \
                   "{\"channel_login\":\"a\",\"username\":\"u1\"}\n" \
                   "{\"channel_login\":\"b\",\"username\":\"u2\"}\n"
        stub = stub_request(:post, url).with(body: expected).to_return(status: 200, body: "")

        expect(client.insert("chat_messages", rows)).to eq(2)
        expect(stub).to have_been_requested
      end

      it "is a no-op for empty/nil rows (no HTTP call)" do
        expect(client.insert("chat_messages", [])).to eq(0)
        expect(client.insert("chat_messages", nil)).to eq(0)
        expect(a_request(:post, url)).not_to have_been_made
      end
    end

    describe "#ping" do
      let(:ping_url) { "http://clickhouse.test:8123/ping" }

      it "GETs /ping and returns true on 200 (no retry, no auth needed)" do
        stub = stub_request(:get, ping_url).to_return(status: 200, body: "Ok.\n")
        expect(client.ping).to be(true)
        expect(stub).to have_been_requested.once
      end

      it "returns false (no raise) when CH is unreachable" do
        stub_request(:get, ping_url).to_raise(HTTP::ConnectionError.new("refused"))
        expect(client.ping).to be(false)
      end
    end

    describe "retry / error handling" do
      it "retries a 5xx with backoff, then succeeds" do
        stub_request(:post, url).to_return({ status: 503, body: "busy" }, { status: 200, body: "" })
        allow(client).to receive(:sleep) # don't actually wait

        expect(client.execute("OPTIMIZE TABLE x")).to be(true)
      end

      it "gives up after MAX_RETRIES on persistent 5xx and raises QueryError" do
        stub_request(:post, url).to_return(status: 503, body: "still busy")
        allow(client).to receive(:sleep)

        expect { client.execute("OPTIMIZE TABLE x") }.to raise_error(Clickhouse::QueryError, /HTTP 503/)
      end

      it "wraps a connection failure in Clickhouse::ConnectionError" do
        stub_request(:post, url).to_raise(HTTP::ConnectionError.new("refused"))
        allow(client).to receive(:sleep)

        expect { client.execute("SELECT 1") }.to raise_error(Clickhouse::ConnectionError, /connection error/)
      end

      it "best_effort insert fails fast — no retry on a 5xx" do
        stub = stub_request(:post, url).to_return(status: 503, body: "busy")

        expect { client.insert("t", [ { a: 1 } ], best_effort: true) }.to raise_error(Clickhouse::QueryError, /HTTP 503/)
        expect(stub).to have_been_requested.once # single attempt, no backoff/retry
      end
    end

    it "reads connection settings from ENV when not given explicitly" do
      allow(ENV).to receive(:fetch).and_call_original
      allow(ENV).to receive(:fetch).with("CLICKHOUSE_HOST", anything).and_return("ch.example")
      allow(ENV).to receive(:fetch).with("CLICKHOUSE_DATABASE", anything).and_return("himrate_x")

      c = described_class.new
      expect(c.host).to eq("ch.example")
      expect(c.database).to eq("himrate_x")
    end
  end

  describe "integration (real ClickHouse)", :clickhouse do
    let(:client) { Clickhouse.client }
    let(:table) { "spec_ch_#{SecureRandom.hex(4)}" }

    before do
      skip "ClickHouse not reachable (set CLICKHOUSE_HOST + run a CH server)" unless client.ping
    end

    it "round-trips DDL -> batch insert -> select against a real server" do
      client.execute("CREATE TABLE #{table} (login LowCardinality(String), n UInt32) ENGINE = MergeTree ORDER BY login")

      inserted = client.insert(table, [ { login: "alpha", n: 1 }, { login: "beta", n: 2 } ])
      expect(inserted).to eq(2)

      rows = client.select("SELECT login, n FROM #{table} ORDER BY login")
      expect(rows.map { |r| r["login"] }).to eq(%w[alpha beta])
      expect(rows.map { |r| r["n"].to_i }).to eq([ 1, 2 ])
    ensure
      begin
        client.execute("DROP TABLE IF EXISTS #{table}")
      rescue Clickhouse::Error
        nil
      end
    end

    it "has applied the committed schema (clickhouse:setup) — chat_messages is queryable" do
      expect { client.execute("SELECT count() FROM chat_messages") }.not_to raise_error
    end

    # Phase 6 M (2026-06-03): integration check that the bloom_filter skipping index actually
    # exists on the CH server, not just in the .sql file. The schema unit spec verifies the file
    # registers the index; this verifies the rake task applied it to the test database. Two
    # provisioning paths converge here — 001's CREATE TABLE (fresh CI db) and 003's ALTER (older
    # databases) — so the post-condition (index visible in `system.data_skipping_indices`) is the
    # contract both must satisfy. Future refactors that drop the index from CREATE TABLE without
    # also delivering it via ALTER would fail this assertion.
    it "has materialized the idx_stream_id bloom_filter skipping index on chat_messages" do
      rows = client.select(<<~SQL.squish)
        SELECT name, type, expr, granularity
        FROM system.data_skipping_indices
        WHERE table = 'chat_messages' AND name = 'idx_stream_id'
      SQL
      expect(rows.size).to eq(1), "expected idx_stream_id index on chat_messages, got: #{rows.inspect}"
      expect(rows.first["type"]).to eq("bloom_filter")
      expect(rows.first["expr"]).to eq("stream_id")
      expect(rows.first["granularity"].to_i).to eq(4)
    end
  end
end
