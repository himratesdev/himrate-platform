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
    candidates = [ query_lang(request), env["HTTP_ACCEPT_LANGUAGE"] ]
    candidates.each do |source|
      locale = match_available(source)
      return locale if locale
    end
    I18n.default_locale
  end

  # Query-only param read; an empty/malformed query string just yields nil.
  def query_lang(request)
    request.GET["lang"].presence
  rescue Rack::QueryParser::ParameterTypeError, Rack::QueryParser::InvalidParameterError
    nil
  end

  def match_available(source)
    return nil if source.blank?

    tag = source.to_s.downcase.scan(/[a-z]{2}/).first
    sym = tag&.to_sym
    sym if sym && I18n.available_locales.include?(sym)
  end
end
