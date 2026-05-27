# frozen_string_literal: true

# TASK-251.14 (PR 1a): thin ClickHouse HTTP client.
#
# ADR DEC-5 (revised 2026-05-27): a hand-rolled client over the `http` gem — the codebase's single
# HTTP stack, same idiom as Twitch::GqlClient — instead of the `click_house` gem. The data-source
# verification found the lightweight CH gems (click_house / clickhouse) are Faraday-based and
# unmaintained since 2022/2017, and would add a second HTTP stack on the hottest data path.
# ClickHouse's HTTP interface is small and protocol-stable, so owning a tested ~200-line wrapper is
# the build-for-years choice. Postgres stays on ActiveRecord; CH is batch-insert + analytic-SELECT
# + DDL only (no AR-ORM over a columnar store).
#
# Talks to the `himrate-clickhouse` accessory over the Kamal Docker network (HTTP :8123). The default
# user is password-protected and the host port is bound to 127.0.0.1 only — internal-only, the same
# model as the db/redis accessories. Call from Sidekiq workers / rake, not the web request cycle:
# the retry backoff sleeps, and analytic queries can run for seconds.
#
# Low-level contract: #execute / #select / #insert interpolate the SQL string and table name
# verbatim (same as ActiveRecord::Base.connection.execute) — pass only static / internal table names,
# never user input. Row VALUES in #insert are safely JSON-encoded, so they are not an injection vector.

module Clickhouse
  class Client
    DEFAULT_PORT = "8123"
    REQUEST_TIMEOUT = 30 # analytic SELECTs / batch INSERTs run longer than an OLTP call
    PING_TIMEOUT = 2     # liveness probe must fail fast — no retry/backoff
    MAX_RETRIES = 3
    BACKOFF_BASE = 1 # seconds
    RETRYABLE_STATUSES = [ 500, 502, 503, 504 ].freeze

    attr_reader :host, :port, :database, :user

    def initialize(host: nil, port: nil, database: nil, user: nil, password: nil)
      @host     = host     || ENV.fetch("CLICKHOUSE_HOST", "localhost")
      @port     = port     || ENV.fetch("CLICKHOUSE_PORT", DEFAULT_PORT)
      @database = database || ENV.fetch("CLICKHOUSE_DATABASE", "himrate_#{Rails.env}")
      @user     = user     || ENV.fetch("CLICKHOUSE_USER", "default")
      @password = password || ENV.fetch("CLICKHOUSE_PASSWORD", "")
    end

    # Execute a statement with no result set (DDL/DML: CREATE, ALTER, INSERT ... VALUES, OPTIMIZE).
    # Returns true on success; raises QueryError with the CH error text on a non-retryable failure.
    def execute(sql)
      post(sql)
      true
    end

    # Run a SELECT and return an Array<Hash> (column name => value). Appends `FORMAT JSON` so CH
    # returns named columns + meta. NB: ClickHouse renders Int64/UInt64 as JSON strings to avoid
    # precision loss — callers needing numeric coercion do it explicitly (typed readers land with the
    # MV read-migration, PR 1d).
    def select(sql)
      body = post("#{sql.strip.chomp(';')} FORMAT JSON")
      return [] if body.to_s.empty?

      parsed = JSON.parse(body)
      parsed["data"] || []
    rescue JSON::ParserError => e
      raise QueryError, "ClickHouse: invalid JSON response (#{e.message})"
    end

    # Batch-insert rows (Array<Hash>) into `table` via JSONEachRow — one JSON object per line. Hash
    # keys must match table column names; omitted columns take their DDL default. Returns the number
    # of rows sent. Empty input is a no-op (no HTTP call).
    def insert(table, rows)
      return 0 if rows.nil? || rows.empty?

      payload = +"INSERT INTO #{table} FORMAT JSONEachRow\n"
      rows.each { |row| payload << "#{JSON.generate(row)}\n" }
      post(payload)
      rows.size
    end

    # Liveness probe — single GET to ClickHouse's dedicated unauthenticated `/ping` endpoint (returns
    # "Ok.\n" with 200 when the server is up). Fast and retry-free by design: callers use it to gate
    # setup / dual-write, so it must answer quickly and return false — not block or raise — when CH is
    # absent. Server liveness only (not DB existence / auth), which is exactly the reachability gate.
    def ping
      HTTP.timeout(PING_TIMEOUT).get("http://#{@host}:#{@port}/ping").status.success?
    rescue HTTP::Error, IO::TimeoutError
      false
    end

    private

    def post(sql, retries: 0)
      response = http_client.post(url, body: sql)
      handle(response, sql, retries)
    rescue HTTP::TimeoutError, IO::TimeoutError => e
      raise_or_retry(ConnectionError.new("ClickHouse timeout: #{e.message}"), retries) { post(sql, retries: retries + 1) }
    rescue HTTP::ConnectionError => e
      raise_or_retry(ConnectionError.new("ClickHouse connection error: #{e.message}"), retries) { post(sql, retries: retries + 1) }
    end

    def handle(response, sql, retries)
      status = response.status.to_i
      return response.body.to_s if status == 200

      # 5xx → transient, retry with backoff. 4xx → query/auth error, fail fast (no retry).
      if RETRYABLE_STATUSES.include?(status) && retries < MAX_RETRIES
        backoff(retries)
        return post(sql, retries: retries + 1)
      end

      raise QueryError, "ClickHouse HTTP #{status}: #{response.body.to_s.truncate(500)}"
    end

    def raise_or_retry(error, retries)
      raise error if retries >= MAX_RETRIES

      backoff(retries)
      yield
    end

    def backoff(retries)
      sleep(BACKOFF_BASE * (2**retries))
    end

    def http_client
      HTTP.timeout(REQUEST_TIMEOUT).headers(
        "X-ClickHouse-User" => @user,
        "X-ClickHouse-Key" => @password,
        "X-ClickHouse-Database" => @database
      )
    end

    def url
      "http://#{@host}:#{@port}/"
    end
  end
end
