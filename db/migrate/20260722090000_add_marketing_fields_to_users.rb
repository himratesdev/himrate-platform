# frozen_string_literal: true

# Email-marketing foundation: capture email provenance + marketing consent at
# registration so we reliably hold a mailable list and can build action-triggered
# campaigns later. email itself already exists on users.
class AddMarketingFieldsToUsers < ActiveRecord::Migration[8.0]
  def up
    execute(<<~SQL)
      ALTER TABLE users
        ADD COLUMN marketing_consent boolean NOT NULL DEFAULT true,
        ADD COLUMN email_source varchar(20),
        ADD COLUMN email_verified boolean NOT NULL DEFAULT false;
    SQL
  end

  def down
    execute(<<~SQL)
      ALTER TABLE users
        DROP COLUMN marketing_consent,
        DROP COLUMN email_source,
        DROP COLUMN email_verified;
    SQL
  end
end
