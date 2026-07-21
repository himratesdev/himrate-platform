# frozen_string_literal: true

# Email-marketing foundation: export the mailable registration list as CSV to stdout.
# Only consented, non-deleted users with an email. Run on the server / via a CI ops
# workflow: `bundle exec rails marketing:export_emails`.
#
#   marketing:export_emails            → all consented users
#   marketing:export_emails SINCE=2026-07-01  → registered on/after a date
namespace :marketing do
  desc "Export the mailable registration list (CSV to stdout)"
  task export_emails: :environment do
    require "csv"

    scope = User.active.where(marketing_consent: true).where.not(email: [ nil, "" ])
    if ENV["SINCE"].present?
      scope = scope.where("created_at >= ?", Time.zone.parse(ENV["SINCE"]))
    end

    # username derives from a user-controlled Google `name` claim → could start with
    # =, +, -, @ and execute as a formula if the export is opened in Excel/Sheets.
    # Neutralise those cells (CSV formula injection).
    sanitize = ->(v) { v.to_s.match?(/\A[=+\-@]/) ? "'#{v}" : v }

    csv = CSV.generate do |out|
      out << %w[email username role tier email_source email_verified registered_at]
      scope.order(:created_at).find_each do |u|
        out << [ u.email, u.username, u.role, u.tier,
                 u.email_source, u.email_verified, u.created_at.iso8601 ].map { |c| sanitize.call(c) }
      end
    end

    puts csv
    warn "Exported #{scope.count} mailable users."
  end
end
