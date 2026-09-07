-- Публичные посты соцсетей (пока Telegram): нужны, чтобы всплеск просмотров можно было ОБЪЯСНИТЬ,
-- а не просто заметить. Без текста поста «в два раза больше просмотров» читается брендом как охват,
-- который можно купить, хотя это мог быть один розыгрыш или репост из крупного канала.
--
-- Ровно то, что видно в публичном превью t.me/s/<handle> — ничего приватного: id поста, время,
-- просмотры, текст и ссылки из него. Хэш текста хранится рядом: по нему одинаковый пост в разных
-- каналах находится одним GROUP BY (репост-сети, скоординированные рассылки).
--
-- ReplacingMergeTree по (платформа, канал, пост): повторные снимки одного поста схлопываются,
-- побеждает последний по captured_at — просмотры у поста растут, и нам нужна свежая цифра.
-- Ретенция 180 дней: сезонность конкурсов видна на полгода, дальше история не нужна.
--
-- Idempotent (IF NOT EXISTS) — применяется `rake clickhouse:setup` на каждом деплое.

CREATE TABLE IF NOT EXISTS social_posts
(
    platform      LowCardinality(String),
    handle        String,
    post_id       String,
    published_at  DateTime,
    views         UInt32,
    text          String CODEC(ZSTD(3)),
    text_hash     UInt64,          -- cityHash64 нормализованного текста: ключ поиска репостов
    links         Array(String),
    has_giveaway  UInt8,           -- в тексте признаки розыгрыша/конкурса (объясняет всплеск)
    captured_at   DateTime DEFAULT now()
)
ENGINE = ReplacingMergeTree(captured_at)
ORDER BY (platform, handle, post_id)
PARTITION BY toYYYYMM(published_at)
TTL published_at + INTERVAL 180 DAY;
