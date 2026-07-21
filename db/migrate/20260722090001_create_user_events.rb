# frozen_string_literal: true

# Append-only lifecycle/behavioral event log — the substrate for action-triggered
# email campaigns («разные рассылки в зависимости от действий пользователя»). Each
# meaningful user action (registered, first channel tracked, subscribed, …) is one
# row; segments and triggers are queries over this table. event_type is an open
# string so new campaigns add events without a migration. metadata jsonb carries
# per-event context. Lifetime (no retention) — low volume, PostgreSQL.
class CreateUserEvents < ActiveRecord::Migration[8.0]
  def up
    execute(<<~SQL)
      CREATE TABLE user_events (
        id uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
        user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
        event_type varchar(50) NOT NULL,
        metadata jsonb NOT NULL DEFAULT '{}',
        occurred_at timestamp(6) without time zone NOT NULL DEFAULT now(),
        created_at timestamp(6) without time zone NOT NULL DEFAULT now()
      );
    SQL

    add_index :user_events, %i[user_id event_type], name: "idx_user_events_user_type"
    add_index :user_events, %i[event_type occurred_at], name: "idx_user_events_type_time"
  end

  def down
    drop_table :user_events
  end
end
