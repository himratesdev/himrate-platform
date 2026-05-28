# frozen_string_literal: true

module PersonalAnalytics
  # TASK-113 BE-3 (CR Nit): общие guards для client-capture ingest — завершают boundary-контракт
  # «drop/clamp невалидное, не падать на insert_all batch». Oversized значение в varchar/int колонке
  # иначе → PG error → весь multi-row batch падает (тот же failure mode что закрыл SF-2 для uuid).
  module Ingest
    MAX_CHANNEL_ID_LEN = 30  # twitch_channel_id varchar(30)
    MAX_LOGIN_LEN = 50       # twitch_login varchar(50)
    PG_INT_MAX = 2_147_483_647 # 4-byte integer columns (amount/months/streak/message_count)

    module_function

    def valid_channel_id?(value)
      string = value.to_s
      string.present? && string.length <= MAX_CHANNEL_ID_LEN
    end

    def truncate_login(value)
      value.presence&.to_s&.slice(0, MAX_LOGIN_LEN)
    end

    # non-negative int в пределах PG 4-byte integer (защита от overflow).
    def clamp_int(value)
      value.to_i.clamp(0, PG_INT_MAX)
    end
  end
end
