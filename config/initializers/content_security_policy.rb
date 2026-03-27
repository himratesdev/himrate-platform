# frozen_string_literal: true

# TASK-015: Content Security Policy
# Protects against XSS, clickjacking, code injection.
# report_only mode on staging — logs violations without blocking.

Rails.application.configure do
  config.content_security_policy do |policy|
    policy.default_src :self
    policy.font_src    :self, :data
    policy.img_src     :self, :data, :https
    policy.object_src  :none
    policy.script_src  :self
    policy.style_src   :self, :unsafe_inline # unsafe_inline required for Flipper UI
    policy.connect_src :self
    policy.frame_ancestors :none
  end

  # Report violations without enforcing (staging).
  # Switch to false after verifying no false positives in logs.
  config.content_security_policy_report_only = true
end
