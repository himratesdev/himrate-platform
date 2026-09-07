# Реестр платных поверхностей (что закрыто, когда OPEN-HOUSE выключен)

Источник правды — код политик (`app/policies/*.rb`); этот файл описывает, что именно откроет
и снова закроет рубильник `open_house_all_features`, чтобы после тест-периода не гадать.

## Рубильник

```bash
# открыть всё зарегистрированным (гость остаётся гостем)
docker exec <web> bin/rails runner 'Flipper.enable(:open_house_all_features)'
# вернуть платные гейты
docker exec <web> bin/rails runner 'Flipper.disable(:open_house_all_features)'
# проверить состояние
docker exec <web> bin/rails runner 'puts Flipper.enabled?(:open_house_all_features)'
```

Механика: `ApplicationPolicy#premium?` и `#business?` считают любого залогиненного пользователя
верхним тиром, `User#brand?` добавляет роль `brand` в `/api/v1/lk/status` (без этого серверный гейт
откроется, а клиентские пейволлы в JS всё равно нарисуют замок). Данные не меняются: тир в БД
остаётся `free`, подписки не создаются, промокоды не тратятся. Выключение мгновенно возвращает
прежнее поведение.

**Что рубильник НЕ делает:** не открывает ничего гостю (публичные страницы без изменений),
не выдаёт права владельца канала (`owns_channel?` / `streamer_on_channel?` — это идентичность по
Twitch, а не тир) и не влияет на движок/вердикты.

## Второй рубильник: гостевой режим `open_house_guest_access`

```bash
docker exec <web> bin/rails runner 'Flipper.enable(:open_house_guest_access)'   # смотреть без входа
docker exec <web> bin/rails runner 'Flipper.disable(:open_house_guest_access)'  # вернуть вход
```

Открывает БЕЗ логина только витрины — те, где нечего показывать «твоего»:

| Открыто гостю | Требует входа даже с флагом |
|---|---|
| `/discover` — кто в эфире | `/home` — личная главная |
| `/graph` — паутинка аудиторий | `/activity` — личная аналитика |
| `/search`, `/creators` — поиск стримеров и блогеров | `/watchlists` — свои списки |
| `/compare`, `/overlap` — сравнение и пересечение | `/channel`, `/grow`, `/social`, `/connect` — свой канал |
| `/streamers/:login`, `/blogger/:login` — карточки | `/settings`, `/business/new` — аккаунт и заявка |
| публичные `/c/:login`, `/top` (и так открыты) | `/moments` — свои моменты |

Механика: `Api::BaseController#authenticate_user_or_guest!` на витринных контроллерах пропускает
запрос без сессии, `ApplicationPolicy#registered?` считает гостя зарегистрированным, а `/lk/status`
отдаёт `guest_access: true` — по нему клиентские скрипты витрин не редиректят на `/login`.
Всё, что завязано на личность (владение каналом, свои трекнутые каналы, команда), для гостя
остаётся ложным по построению — открыть чужой аккаунт этим флагом нельзя.

Два флага независимы: `open_house_guest_access` пускает без входа, `open_house_all_features`
снимает платные замки. Для «полностью открытого» демо нужны оба.

## Границы доступа (канон access-model v2)

| Поверхность | Бесплатно | Платно |
|---|---|---|
| Расширение (зритель) | всё | — |
| Публичная карточка `/c/:login` | вердикт эфира, надёжность, реальные зрители | детализация эфира, история за период |
| ЛК зрителя (главная, активность, куда пойти, вотчлисты, моменты, паутинка) | всё зарегистрированным | — |
| ЛК стримера (свой канал, рост, соцсети, подключение) | своему каналу | чужие каналы |
| Брендовые инструменты | — | поиск стримеров, блогеров, сравнение, пересечение, карточка стримера |

## Что конкретно закрыто платным гейтом

**Брендовые (роль brand / тир business):**

| Что | Где в коде |
|---|---|
| Поиск стримеров `/search` + API `brand/streamers/search` | `BrandSearchPolicy` |
| Поиск блогеров `/creators` | `BrandSearchPolicy` |
| Сравнение каналов `/compare` | `CompareChannelsPolicy` |
| Пересечение аудиторий `/overlap` | `AudienceOverlapPolicy` |
| Карточка стримера `/streamers/:login` (30-дневный трек-рекорд) | `StreamerCardPolicy` |
| Слой `role_tools` публичной карточки (BAA) | `ChannelPolicy#card_role_tools?` |

**Премиальные (тир premium ИЛИ канал в трекинге ИЛИ владелец):**

| Что | Где в коде |
|---|---|
| Слой `period_depth` карточки (история за период) | `ChannelPolicy#card_period_depth?` |
| Исторические тренды канала | `ChannelPolicy#view_trends_historical?` |
| Bot-raid chain | `BotChainPolicy` |
| Снимки Trust Index | `TrustSnapshotPolicy` |
| Трекинг канала (`POST /channels/:id/track`) | `ChannelPolicy#track?` — премиум, бизнес **или владелец канала** |

**Только регистрация (не платно, но не гостю):** слой `live_drill` карточки — детализация ЖИВОГО
эфира (`ChannelPolicy#card_live_drill?`), паутинка `/graph`, личная аналитика, вотчлисты, моменты,
транскрипты клипов (10/мес бесплатно).

## Альтернатива рубильнику — промокоды (адресно, с истечением)

```bash
docker exec <web> bin/rails "promo:mint[brand_pack_trial,5]"   # business на 14 дней
docker exec <web> bin/rails "promo:mint[vip_lifetime,2]"       # premium навсегда
docker exec <web> bin/rails "promo:mint[friend_referral,10]"   # premium на 30 дней
```

Код вводится в `/settings`; грант живёт как обычная подписка и закрывается ночным
`PromoExpiryWorker`. Это предпочтительный путь, когда нужно открыть доступ конкретным людям,
а не всему интернету.
