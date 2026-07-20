# frozen_string_literal: true

# TASK-015: Content Security Policy
# Protects against XSS, clickjacking, code injection.
# report_only mode on staging — logs violations without blocking.

Rails.application.configure do
  # Analytics endpoints (TASK-060): Yandex.Metrika + Google Analytics 4 load their
  # own scripts and beacon back — allow their hosts so the policy holds when it flips
  # to enforce. img_src already allows :https (Metrika pixel beacon).
  metrika = "https://mc.yandex.ru"
  google_tag = "https://www.googletagmanager.com"
  ga_collect = [ "https://www.google-analytics.com", "https://*.google-analytics.com", "https://*.analytics.google.com" ]

  config.content_security_policy do |policy|
    policy.default_src :self
    policy.font_src    :self, :data
    policy.img_src     :self, :data, :https
    policy.object_src  :none
    policy.script_src  :self, metrika, google_tag
    policy.style_src   :self, :unsafe_inline # unsafe_inline required for Flipper UI
    policy.connect_src :self, metrika, *ga_collect
    policy.frame_src   metrika # Metrika Webvisor session replay iframe
    policy.frame_ancestors :none
  end

  # Report violations without enforcing (staging).
  # Switch to false after verifying no false positives in logs.
  config.content_security_policy_report_only = true
end
