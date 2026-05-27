# frozen_string_literal: true

# TASK-251.14: ClickHouse namespace — errors + the client factory.
# See Clickhouse::Client (app/services/clickhouse/client.rb) for the HTTP client itself and the
# ADR DEC-5 rationale for hand-rolling it over the `http` gem.
module Clickhouse
  class Error < StandardError; end
  class ConnectionError < Error; end
  class QueryError < Error; end

  # Build a client from ENV. Cheap + stateless (one HTTP connection per request, like GqlClient) so
  # it is safe to instantiate per use. No boot-time connection — CH may be down at boot and must
  # never crash the app.
  def self.client
    Client.new
  end
end
