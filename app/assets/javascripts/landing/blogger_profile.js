// Brand-side blogger social profile (screen 61) — wires REAL descriptive cross-platform analytics into
// the faithful Pencil export for ANY streamer (login from /app/blogger/:login). Same keyless engine as
// screen 50: GET /api/v1/social/streamers/:login (Twitch socialMedias seed → Telegram/YouTube public
// metrics: subs / reach / ER / просматриваемость). Brand-gated shell (/api/v1/lk/status → /login).
//
// NO fraud verdict on socials (PO 2026-07-21): the design's «Bot-corrected аудитория», «реальные
// подписчики», «−20% боты», «наш расчёт» tag and the «Доверие и методология» card are stripped /
// repurposed — descriptive numbers only. Demographics / geo / посты-reels / прогноз цен / динамика /
// рост need creds or accrued history we don't have yet → honestly deferred (dimmed + «скоро»).
// CSP-safe (external asset, textContent not innerHTML, no eval).
(function () {
  "use strict";

  var NAMES = { telegram: "Telegram", youtube: "YouTube", vk: "VK", instagram: "Instagram", tiktok: "TikTok" };
  var PLATFORMS = ["telegram", "youtube", "vk", "instagram", "tiktok"];
  var AB = { telegram: "tg", youtube: "yt", vk: "vk", instagram: "ig", tiktok: "tt" }; // 61's per-platform anchor suffix

  function q(name, root) { return (root || document).querySelector('[data-pencil-name="' + cssEsc(name) + '"]'); }
  function cssEsc(s) { return String(s).replace(/"/g, '\\"'); }
  function setT(name, text) { var n = q(name); if (n != null && text != null) n.textContent = text; }
  function hide(n) { if (n) n.style.display = "none"; }
  function dim(n) { if (n) n.style.opacity = "0.45"; }
  function fmt(n) {
    if (n == null || isNaN(n)) return "—";
    return Math.round(n).toString().replace(/\B(?=(\d{3})+(?!\d))/g, " ");
  }
  var HEADERS = { Accept: "application/json", "Accept-Language": "ru" };
  function apiGet(p) {
    return fetch(p, { headers: HEADERS, credentials: "same-origin" }).then(function (r) { return r.ok ? r.json() : Promise.reject(r.status); });
  }

  function sumSubs(platforms) {
    var total = 0, any = false;
    PLATFORMS.forEach(function (p) {
      var d = platforms[p];
      if (d && d.available && d.subscribers) { total += d.subscribers; any = true; }
    });
    return any ? total : null;
  }
  // The «aggregate» blocks (KPIs, Публикации) show ONE platform's descriptive metrics — pick the richest
  // available: Telegram first (keyless, richest preview) then YouTube.
  function primary(platforms) {
    if (platforms.telegram && platforms.telegram.available) return platforms.telegram;
    if (platforms.youtube && platforms.youtube.available) return platforms.youtube;
    return null;
  }
  function plural(n, one, few, many) {
    var m10 = n % 10, m100 = n % 100;
    if (m10 === 1 && m100 !== 11) return one;
    if (m10 >= 2 && m10 <= 4 && (m100 < 10 || m100 >= 20)) return few;
    return many;
  }
  function setKPI(slot, label, value, sub) {
    if (label != null) setT("KPILT " + slot, label);
    if (value != null) setT("KPIV " + slot, value);
    if (sub != null) setT("KPIS " + slot, sub);
  }

  function stripFraud() {
    hide(q("Card Доверие"));               // trust/methodology card — «bot-corrected», not computed
    hide(q("KPITag Реальная аудитория"));  // «наш расчёт» fraud tag on the hero KPI
    hide(q("KPI Подписчики всего"));        // raw-vs-corrected pair → keep only the descriptive sum
    hide(q("KPI Div"));                     // one divider left over from the hidden KPI (best-effort)
    hide(q("PromoOrg"));                    // promo vs organic split — we do not classify posts
    setT("PillT Дедуплицировано HimRate", "по данным Twitch"); // footprint is from Twitch socialMedias — no cross-platform dedup claim
    // per-account «реальные подписчики» label → neutral (mirrors the descriptive rule)
    PLATFORMS.forEach(function (p) { setT("AcctL " + AB[p], "подписчиков"); });
  }

  // 5 KPI slots → 4 real descriptive metrics (Подписчики всего hidden as redundant).
  function renderKPIs(platforms) {
    var total = sumSubs(platforms);
    var m = (primary(platforms) || {}).metrics || {};
    setKPI("Реальная аудитория", "Суммарная аудитория", total != null ? fmt(total) : "—", null);
    hide(q("KPIS Реальная аудитория")); // hide the «↑ %/мес» sub — growth is shown in its own card
    setKPI("Индекс цитирования", "Средний ER", m.er_percent != null ? m.er_percent + "%" : "—", "вовлечённость");
    setKPI("Рекл. охват", "Рекл. охват", m.avg_views != null ? fmt(m.avg_views) : "—", "в среднем на пост");
    setKPI("Дневной охват", "Просматриваемость", m.view_sub_ratio != null ? m.view_sub_ratio + "%" : "—", "охват ÷ подписчики");
  }

  function renderPublications(platforms) {
    var pr = primary(platforms), m = (pr && pr.metrics) || {};
    setT("SV ER · вовлечённость", m.er_percent != null ? m.er_percent + "%" : "—");
    setT("SV Просматриваемость", m.view_sub_ratio != null ? m.view_sub_ratio + "%" : "—");
    setT("SV Ср. просмотры поста", m.avg_views != null ? fmt(m.avg_views) : "—");
    setT("SV ERR · охватный ER", "—"); // reach-ER is not distinctly available from the public preview
    // hide the «↑ п.п.» period-over-period deltas — we don't compute them here
    ["ER · вовлечённость", "ERR · охватный ER", "Просматриваемость", "Ср. просмотры поста"].forEach(function (s) { hide(q("STt " + s)); });
    setT("CHS Публикации в ленте", pr ? ("по данным " + (pr === platforms.telegram ? "Telegram" : "YouTube") + "-превью") : "нет данных");
  }

  // «Связанные аккаунты» = the Twitch socialMedias footprint (honest, we own the seed). `footprint`
  // maps platform → the socialMedias entry ({handle, url}); `platforms` carries analysed metrics.
  function renderAccounts(platforms, footprint) {
    PLATFORMS.forEach(function (p) {
      var ab = AB[p], d = platforms[p], f = footprint[p], card = q("Acct " + ab);
      if (!card) return;
      if (!f) { hide(card); return; } // not linked on Twitch at all → remove the demo card
      // real handle from the footprint (honest — never the design's demo handle)
      if (f.handle) setT("AcctH " + ab, "@" + String(f.handle).replace(/^@/, "")); else hide(q("AcctH " + ab));
      if (d && d.available) {
        setT("AcctV " + ab, fmt(d.subscribers));
        var er = (d.metrics || {}).er_percent;
        setT("AcctERt " + ab, er != null ? "ER " + er + "%" : "ER —");
      } else {
        dim(card); // linked on Twitch but not analysed yet (VK dropped / IG-TT phase-2)
        setT("AcctV " + ab, "—");
        setT("AcctERt " + ab, "скоро");
      }
    });
  }

  // Sections that show ONLY fabricated demo data today (measured demographics/geo need YouTube
  // owner-OAuth; динамика/рост need accrued history; посты-reels / прогноз цен are unbuilt backend).
  // Per the no-fabricated-numbers rule we HIDE them — a dimmed fake number is still a fake number.
  // They come back, wired, as the creds/history/backend land.
  function renderDeferred() {
    ["Card Демография", "Card Гео", "Card Динамика", "Card Посты", "Card Прогноз цен", "Card Рост"]
      .forEach(function (n) { hide(q(n)); });
  }

  function renderHeader(profile) {
    var socials = (profile && profile.socials) || [];
    if (profile && profile.login) setT("Handle", "@" + String(profile.login).replace(/^@/, ""));
    setT("Plat Count", socials.length + " " + plural(socials.length, "площадка", "площадки", "площадок"));
  }

  function render(profile) {
    var platforms = (profile && profile.platforms) || {};
    var footprint = {};
    ((profile && profile.socials) || []).forEach(function (s) { if (s && s.platform) footprint[s.platform] = s; });
    stripFraud();
    renderHeader(profile);
    renderKPIs(platforms);
    renderPublications(platforms);
    renderAccounts(platforms, footprint);
    renderDeferred();
  }

  var pollTimer;
  function load(login) {
    apiGet("/api/v1/social/streamers/" + encodeURIComponent(login))
      .then(function (resp) {
        var d = (resp && resp.data) || {};
        clearTimeout(pollTimer);
        if (d.status === "pending") { pollTimer = setTimeout(function () { load(login); }, 6000); return; }
        render(d);
      })
      .catch(function () { render({}); });
  }

  function loginFromPath() {
    var m = location.pathname.match(/\/app\/blogger\/([A-Za-z0-9_]+)/);
    if (m) return m[1];
    return new URLSearchParams(location.search).get("login") || "";
  }

  fetch("/api/v1/lk/status", { headers: { Accept: "application/json" }, credentials: "same-origin" })
    .then(function (r) { return r.ok ? r.json() : {}; })
    .then(function (s) {
      if (!s || !s.authenticated) { window.location.href = "/login"; return; }
      var login = loginFromPath();
      if (login) load(login); else render({});
    })
    .catch(function () { window.location.href = "/login"; });
})();
