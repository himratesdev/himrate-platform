# frozen_string_literal: true

module PersonalAnalytics
  # TASK-113 BE-5 (FR-012 / M13 export): async-сборка JSON-архива через ExportBuilder + запись в
  # Rails.cache на EXPORT_TTL (24h) + GDPR consent_log append (action='export_completed').
  # flag-gated :pva. Sidekiq retry 3 (transient errors). Cache-key стабильный per job_id; payload
  # = JSON-string (Hash → to_json в писателе; reader парсит наоборот).
  class ExportWorker
    include Sidekiq::Job
    sidekiq_options queue: :default, retry: 3

    EXPORT_TTL = 24.hours

    def self.cache_key(job_id)
      "pva:export:#{job_id}"
    end

    def perform(user_id, job_id)
      return unless Flipper.enabled?(:pva)

      data = PersonalAnalytics::Export::ExportBuilder.call(user_id)
      return if data.nil? # user deleted between enqueue + run → no-op

      Rails.cache.write(self.class.cache_key(job_id), data.to_json, expires_in: EXPORT_TTL)
      user = User.find_by(id: user_id)
      PersonalAnalytics::Privacy::ConsentLogger.log!(user, action: "export_completed", job_id: job_id) if user
    end
  end
end
