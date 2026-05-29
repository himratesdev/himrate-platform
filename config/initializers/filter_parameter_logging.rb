# frozen_string_literal: true

# Be sure to restart your server when you modify this file.

# Configure parameters to be partially matched (e.g. passw matches password) and filtered from the log file.
# Use this to limit dissemination of sensitive information.
# See the ActiveSupport::ParameterFilter documentation for supported notations and behaviors.
Rails.application.config.filter_parameters += [
  :passw, :email, :secret, :token, :_key, :crypt, :salt, :certificate, :otp, :ssn, :cvv, :cvc
]

# BUG-OAUTH-MV3 (CR iter-1 MF-1): redact chromiumapp.org redirect URLs from Rails'
# `ActionController::Redirecting` "Redirected to <URL>" log line. Without this filter,
# the redirect target — which carries Base64-encoded JWT payload в query string for
# Chrome MV3 extension auth flow — would be written к Loki / on-disk logs at INFO
# level. config.filter_parameters does NOT touch URL strings in redirect log lines —
# config.filter_redirect is the right primitive. Pattern matches against full URL;
# pinning host = chromiumapp.org (canonical для chrome.identity.getRedirectURL()).
Rails.application.config.filter_redirect += [ /chromiumapp\.org/ ]
