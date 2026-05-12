# frozen_string_literal: true

# TASK-090 OQ-4 (CR A3): single source of truth for per-request locale
# resolution. Both MaintenanceMode (Rack middleware) and Api::BaseController
# previously rolled their own logic — the middleware's was the more complete
# one (?lang= query param wins over Accept-Language, falls back to
# I18n.default_locale, only accepts I18n.available_locales). That behavior is
# preserved here and shared so the two paths can never drift.
#
# Input is a Rack env hash (middleware has it directly; the controller passes
# `request.env`). We use Rack::Request#GET so only the query string is parsed —
# never the request body (a maintenance 503 must not depend on POST/PUT bodies).
module LocaleResolver
  module_function

  # Resolves the request locale as a Symbol guaranteed to be in
  # I18n.available_locales (falls back to I18n.default_locale).
  def call(env)
    request = Rack::Request.new(env)
    match_available(query_lang(request)) ||
      match_accept_language(env["HTTP_ACCEPT_LANGUAGE"]) ||
      I18n.default_locale
  end

  # Query-only param read; an empty/malformed query string just yields nil.
  def query_lang(request)
    request.GET["lang"].presence
  rescue Rack::QueryParser::ParameterTypeError, Rack::QueryParser::InvalidParameterError
    nil
  end

  # Single language tag → available-locale Symbol or nil (used for ?lang=).
  def match_available(source)
    return nil if source.blank?

    tag = source.to_s.downcase[/[a-z]{2}/]
    sym = tag&.to_sym
    sym if sym && I18n.available_locales.include?(sym)
  end

  # Accept-Language with q-value preference (RFC 9110 §12.5.4): "fr-CA,ru;q=0.9"
  # → :ru, not :fr (which we don't support). Parses each entry's q-weight
  # (default 1.0), highest-first; ties keep header order; returns the first
  # supported locale.
  def match_accept_language(header)
    return nil if header.blank?

    header.split(",").each_with_index.filter_map { |entry, i| parse_language_entry(entry, i) }
          .min_by { |_locale, q, i| [ -q, i ] }
          &.first
  end

  # "ru;q=0.9" → [:ru, 0.9, index] when :ru is supported, else nil.
  # Malformed/absent q → 1.0.
  def parse_language_entry(entry, index)
    tag_part, *params = entry.strip.split(";")
    locale = match_available(tag_part)
    return nil unless locale

    q = params.find { |p| p.strip.start_with?("q=") }&.then { |p| Float(p.strip[2..], exception: false) }
    [ locale, q || 1.0, index ]
  end
end
