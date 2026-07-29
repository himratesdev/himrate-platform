// Streamer cross-platform socials (screen 50 «Мои соцсети») — wires REAL descriptive analytics into the
// faithful Pencil export. Auth-gated: /api/v1/lk/status → /login. Data: GET /api/v1/social/streamers/:login
// (login = own twitch_login from /user/me), the descriptive engine (Twitch socialMedias seed → Telegram
// & YouTube public metrics: subs / reach / ER / growth).
//
// NO fraud verdict on socials (PO 2026-07-21): the design's «Multi-Platform Trust Score», «РЕАЛЬНАЯ
// АУДИТОРИЯ … −N ботов» and per-card «Реальная ауд. %» are hidden — we show neutral numbers only. The
// «real audience» hero is repurposed to a plain SUM of subscribers. Telegram + YouTube populate; VK /
// Instagram / TikTok are footprint-known but metric-deferred (honest «Аналитика скоро»); demographics /
// geo need YouTube owner-OAuth (deferred). CSP-safe, no eval.
(function () {
  "use strict";

  var NAMES = { telegram: "Telegram", youtube: "YouTube", vk: "VK", instagram: "Instagram", tiktok: "TikTok" };
  var PLATFORMS = ["telegram", "youtube", "vk", "instagram", "tiktok"];

  function q(name, root) { return (root || document).querySelector('[data-pencil-name="' + cssEsc(name) + '"]'); }
  function cssEsc(s) { return String(s).replace(/"/g, '\\"'); }
  function setT(name, text) { var n = q(name); if (n != null && text != null) n.textContent = text; }
  function hide(n) { if (n) n.style.display = "none"; }
  function dim(n) { if (n) { n.style.opacity = "0.5"; } }
  function fmt(n) {
    if (n == null || isNaN(n)) return "—";
    return Math.round(n).toString().replace(/\B(?=(\d{3})+(?!\d))/g, " ");
  }
  var HEADERS = { Accept: "application/json", "Accept-Language": "ru" };
  function apiGet(p) {
    return fetch(p, { headers: HEADERS, credentials: "same-origin" }).then(function (r) { return r.ok ? r.json() : Promise.reject(r.status); });
  }

  // The Stat blocks are `Stat · <Label> <Platform>` wrappers each holding a `Stat V` value node.
  function setStat(platformName, label, value) {
    var wrap = q("Stat · " + label + " " + platformName);
    if (!wrap) return;
    var v = q("Stat V", wrap);
    if (v && value != null) v.textContent = value;
  }

  function hideFraud() {
    // Fraud/накрутка heroes + per-card «Реальная ауд.» — we do not compute a real-audience verdict on socials.
    ["Hero · Trust Score", "Bot Chip", "Score Row", "Score"].forEach(function (n) { hide(q(n)); });
    PLATFORMS.forEach(function (p) { hide(q("Stat · Реальная ауд. " + NAMES[p])); });
  }

  // Repurpose the «РЕАЛЬНАЯ АУДИТОРИЯ ПО ВСЕМ ПЛОЩАДКАМ» hero into a plain, honest sum of subscribers.
  function renderSummary(platforms) {
    var total = 0, any = false;
    PLATFORMS.forEach(function (p) {
      var d = platforms[p];
      if (d && d.available && d.subscribers) { total += d.subscribers; any = true; }
    });
    setT("Real Headline", "Суммарная аудитория по площадкам");
    setT("Real Label", "суммарный охват привязанных площадок — не вердикт достоверности");
    if (any) setT("Real N", fmt(total)); else hide(q("Real Nums"));
  }

  // «Вклад площадок» bars → plain subscriber contribution per platform (no «real audience»).
  function renderBars(platforms) {
    var subs = {}, max = 0;
    PLATFORMS.forEach(function (p) {
      var d = platforms[p];
      subs[p] = (d && d.available && d.subscribers) ? d.subscribers : 0;
      if (subs[p] > max) max = subs[p];
    });
    PLATFORMS.forEach(function (p) {
      var name = NAMES[p];
      if (subs[p] > 0) {
        setT("Bar Val · " + name, fmt(subs[p]));
        var fill = q("Bar Fill · " + name);
        if (fill && max > 0) fill.style.width = Math.max(3, Math.round(subs[p] / max * 100)) + "%";
      } else {
        hide(q("Bar · " + name));
      }
    });
  }

  function renderCard(p, data, linked) {
    var name = NAMES[p];
    var card = q("Card · " + name);
    if (!card) return;

    if (data && data.available) {
      setT("Foll N · " + name, fmt(data.subscribers));
      // avg views ≈ reach per post (the descriptive reach number the preview affords)
      setStat(name, "Охват / мес", fmt((data.metrics || {}).avg_views));
      var er = (data.metrics || {}).er_percent;
      setStat(name, "ER", er != null ? er + "%" : "—");
      // Growth: only when a prior snapshot exists (accumulates over time) — otherwise hide the delta.
      var g = data.growth && (data.growth["30d"] || data.growth["90d"]);
      if (g && g.pct != null) setT("Delta T · " + name, (g.pct >= 0 ? "+" : "") + g.pct + "% · 30 дней");
      else hide(q("Delta · " + name));
      return;
    }

    // Linked on Twitch but no descriptive metrics yet (VK dropped / IG-TT phase-2 / fetch failed).
    if (linked[p]) {
      dim(card);
      setT("Foll N · " + name, "—");
      setT("Delta T · " + name, "Аналитика скоро");
      hide(q("Delta · " + name));
      setStat(name, "Охват / мес", "—");
      setStat(name, "ER", "—");
    } else {
      hide(card); // not linked on Twitch at all
    }
  }

  // Replace a card's fabricated demo content with a clean titled «Скоро появится» placeholder (no fake
  // numbers, structure-agnostic). CSP-safe: textContent + inline style, no innerHTML/eval.
  function markSoon(cardAnchor, title) {
    var card = q(cardAnchor);
    if (!card) return;
    Array.prototype.slice.call(card.children).forEach(hide); // drop the design's fabricated content
    var box = document.createElement("div");
    box.style.cssText = "padding:24px 4px;font-family:Inter,system-ui,sans-serif;";
    var h = document.createElement("div");
    h.textContent = title;
    h.style.cssText = "font-size:16px;font-weight:600;color:#F4F4F7;margin-bottom:6px;";
    var s = document.createElement("div");
    s.textContent = "Скоро появится";
    s.style.cssText = "font-size:13px;color:#9A9AA9;";
    box.appendChild(h);
    box.appendChild(s);
    card.appendChild(box);
  }

  function renderDeferredPanels() {
    // Demographics + geo (measured age/gender/country) can't be sourced for an arbitrary channel without
    // owner authorization — private everywhere (same dead-end as VK). Deferred with «Скоро появится», no
    // fabricated data (PO 2026-07-29). Was: dim() — that left the design's fake bars visible at 0.5.
    markSoon("Card · Демография", "Демография");
    markSoon("Card · География", "География");
  }

  function render(profile) {
    var platforms = (profile && profile.platforms) || {};
    var linked = {};
    ((profile && profile.socials) || []).forEach(function (s) { linked[s.platform] = true; });

    hideFraud();
    renderSummary(platforms);
    renderBars(platforms);
    PLATFORMS.forEach(function (p) { renderCard(p, platforms[p], linked); });
    renderDeferredPanels();
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

  function boot() {
    apiGet("/api/v1/user/me")
      .then(function (resp) {
        var u = (resp && resp.data) || {};
        if (!u.twitch_login) {
          // No Twitch linked → no socials to discover. Honest CTA in place of the cards.
          setT("Real Headline", "Привяжите Twitch");
          setT("Real Label", "Соцсети находятся автоматически по вашему каналу Twitch");
          hide(q("Real Nums"));
          return;
        }
        load(u.twitch_login);
      })
      .catch(function () { render({}); });
  }

  fetch("/api/v1/lk/status", { headers: { Accept: "application/json" }, credentials: "same-origin" })
    .then(function (r) { return r.ok ? r.json() : {}; })
    .then(function (s) { if (!s || !s.authenticated) { window.location.href = "/login"; return; } boot(); })
    .catch(function () { window.location.href = "/login"; });
})();
