// Brand creator discovery (screen 60) — wires REAL ranked data into the faithful Pencil export,
// REUSING the existing brand streamer search (GET /api/v1/brand/streamers/search — real 30-day audience
// over trends_daily_aggregates, already scale-correct to ~10k channels; NO new backend). The result
// card opens the cross-platform blogger profile (screen 61, /app/blogger/:login). Auth-gated:
// /api/v1/lk/status → /login; 403 → in-page brand paywall.
//
// Twitch-anchored + descriptive (PO 2026-07-22): the design's social-platform / topic filter chips need
// a footprint index / taxonomy → deferred (dimmed, «Скоро»); per-card «фейки N%», «480K ₽» price
// forecast, social «ER», the per-card social-platform icons, and the «shield» fraud pill are stripped
// (no fraud verdict). Real: name, reputation label, topic (Twitch game), real audience (Twitch ERV).
// The real filters (category/language/min_real/classification/sort/page) stay URL-drivable. CSP-safe:
// external asset, same-origin fetch, textContent (no eval / no innerHTML on user data).
(function () {
  "use strict";

  var API = "/api/v1/brand/streamers/search";
  var SORTS = [
    { key: "real_avg", label: "Реальная аудитория" },
    { key: "real_pct", label: "% реальных" },
    { key: "streams_per_week", label: "Частота эфиров" },
  ];

  // SA-2: platform filter chips → the API `platform` param (backed by the channel_social_links footprint
  // index). Single-select toggle. Topic chips (Бьюти/Гейминг/…) stay deferred (no Twitch-game taxonomy).
  var PLATFORM_CHIPS = {
    "Chip · Telegram": "telegram", "Chip · YouTube": "youtube", "Chip · VK": "vk",
    "Chip · Instagram": "instagram", "Chip · TikTok": "tiktok",
  };

  // ti_avg → colour band, in lockstep with the ERV label the API returns (both derive from ti).
  function tiColor(ti) {
    if (ti == null || isNaN(ti)) return "#9A9AA9";
    if (ti >= 80) return "#25D9A4"; // green — real / no anomalies
    if (ti >= 50) return "#F5C451"; // yellow — anomaly
    return "#F0616D"; // red — significant anomaly
  }

  function q(root, name) { return (root || document).querySelector('[data-pencil-name="' + name + '"]'); }
  function qp(root, prefix) { return (root || document).querySelector('[data-pencil-name^="' + prefix + '"]'); }
  function setText(root, name, text) { var n = q(root, name); if (n != null && text != null) n.textContent = text; }
  function setTextP(root, prefix, text) { var n = qp(root, prefix); if (n != null && text != null) n.textContent = text; }
  function hide(node) { if (node) node.style.display = "none"; }
  function fmt(n) {
    if (n == null || isNaN(n)) return "—";
    return Math.round(n).toString().replace(/\B(?=(\d{3})+(?!\d))/g, " ");
  }
  function initials(name) {
    if (!name) return "?";
    var s = name.replace(/[^A-Za-zА-Яа-я0-9]/g, "");
    return (s.slice(0, 2) || "?").toUpperCase();
  }
  function plural(n, one, few, many) {
    n = Math.abs(n) % 100; var n1 = n % 10;
    if (n > 10 && n < 20) return many;
    if (n1 > 1 && n1 < 5) return few;
    if (n1 === 1) return one;
    return many;
  }

  function currentParams() {
    var u = new URLSearchParams(window.location.search), p = {};
    ["category", "language", "platform", "min_real", "frequency", "classification", "sort", "page"].forEach(function (k) {
      if (u.get(k)) p[k] = u.get(k);
    });
    if (!p.sort) p.sort = "real_avg";
    return p;
  }
  function pushParams(p) {
    var u = new URLSearchParams();
    Object.keys(p).forEach(function (k) { if (p[k] != null && p[k] !== "") u.set(k, p[k]); });
    var qs = u.toString();
    window.history.replaceState(null, "", qs ? "?" + qs : window.location.pathname);
  }

  // ---- results ----
  var grid, cardTemplate;
  function captureTemplate() {
    var firstCard = document.querySelector('[data-pencil-name^="Card · "]');
    if (!firstCard) return false;
    grid = firstCard.parentNode;
    cardTemplate = firstCard.cloneNode(true);
    // Fraud strip on the TEMPLATE so every clone is clean: fake-%, price forecast, social ER, and the
    // per-card social-platform icons (footprint not indexed at scale → never a fake platform claim).
    [ qp(cardTemplate, "Fake · "), qp(cardTemplate, "Price · "), qp(cardTemplate, "ER · "), qp(cardTemplate, "PRow · ") ]
      .forEach(hide);
    return true;
  }
  function clearCards() {
    Array.prototype.slice
      .call(grid.querySelectorAll('[data-pencil-name^="Card · "], [data-pencil-name="Empty"], [data-pencil-name="Paywall"]'))
      .forEach(function (n) { n.remove(); });
  }

  function buildCard(s, rank) {
    var card = cardTemplate.cloneNode(true);
    card.setAttribute("data-pencil-name", "Card · " + s.login);
    setTextP(card, "Rank · ", String(rank));
    setTextP(card, "AvT · ", initials(s.display_name || s.login));
    setTextP(card, "Nm · ", s.display_name || s.login);
    setTextP(card, "Cat · ", "@" + s.login + (s.category ? " · " + s.category : ""));

    // Reputation label — canonical ERV/classification label (legal-safe) + colour from ti band.
    var color = tiColor(s.ti_avg);
    if (s.classification_label) setText(card, "Rel Label", s.classification_label);
    var relLabel = q(card, "Rel Label"); if (relLabel) relLabel.style.color = color;
    var relDot = q(card, "Rel Dot"); if (relDot) relDot.style.backgroundColor = color;

    // Real audience — the Twitch ERV real-viewer count (we own it); keep the «реальная аудитория» label.
    setTextP(card, "RealV · ", fmt(s.real_avg_viewers));
    var realNode = qp(card, "RealV · "); if (realNode) realNode.style.color = color;

    // Open → the cross-platform blogger profile (screen 61).
    var openTo = "/app/blogger/" + encodeURIComponent(s.login);
    var chev = qp(card, "Chev · "); if (chev) chev.style.cursor = "pointer";
    card.style.cursor = "pointer";
    card.addEventListener("click", function () { window.location.href = openTo; });
    return card;
  }

  function renderResults(data) {
    var results = (data && data.results) || [];
    setText(document, "TB Found", "Найдено " + fmt(data.total) + " " + plural(data.total, "стример", "стримера", "стримеров"));
    setText(document, "TB Show", "ранжировано по реальной аудитории");
    var active = SORTS.filter(function (x) { return x.key === (data.sort || "real_avg"); })[0] || SORTS[0];
    setText(document, "Sort T", active.label);

    clearCards();
    if (!results.length) { renderEmpty("Ничего не найдено. Смягчите фильтры."); return; }
    var perPage = data.per_page || results.length;
    var base = ((data.page || 1) - 1) * perPage;
    results.forEach(function (s, i) { grid.appendChild(buildCard(s, base + i + 1)); });
  }

  function renderEmpty(msg) {
    var box = document.createElement("div");
    box.setAttribute("data-pencil-name", "Empty");
    box.style.cssText = "width:100%;padding:48px 16px;text-align:center;color:#9A9AA9;font-family:Inter,system-ui,sans-serif;font-size:15px;";
    box.textContent = msg;
    clearCards();
    grid.appendChild(box);
  }

  function renderPaywall() {
    var box = document.createElement("div");
    box.setAttribute("data-pencil-name", "Paywall");
    box.style.cssText = "width:100%;padding:48px 20px;text-align:center;color:#C7C7D1;font-family:Inter,system-ui,sans-serif;";
    box.innerHTML =
      '<div style="font-size:18px;font-weight:700;margin-bottom:8px;">Поиск креаторов — для бренд-аккаунтов</div>' +
      '<div style="font-size:14px;color:#9A9AA9;max-width:460px;margin:0 auto 20px;">Ранжирование по реальной аудитории доступно на бизнес-тарифе. Подключите бренд-доступ, чтобы искать креаторов и открывать их кросс-платформенные профили.</div>' +
      '<a href="/brands" style="display:inline-block;background:#7B5CFA;color:#fff;text-decoration:none;padding:11px 20px;border-radius:12px;font-weight:600;font-size:14px;">Узнать о бренд-тарифах</a>';
    clearCards();
    grid.appendChild(box);
    setText(document, "TB Found", "");
  }

  function load() {
    var u = new URLSearchParams(currentParams());
    fetch(API + "?" + u.toString(), { headers: { Accept: "application/json", "Accept-Language": "ru" }, credentials: "same-origin" })
      .then(function (r) {
        if (r.status === 403) { renderPaywall(); return null; }
        if (!r.ok) throw new Error("HTTP " + r.status);
        return r.json();
      })
      .then(function (d) { if (d) renderResults(d); })
      .catch(function (e) {
        if (window.console) console.warn("[brand_creators] load failed:", e);
        setText(document, "TB Found", "—");
        renderEmpty("Не удалось загрузить результаты. Попробуйте позже.");
      });
  }

  // ---- controls ----
  function wireSort() {
    var ctrl = q(document, "Sort Ctrl"); if (!ctrl) return;
    ctrl.style.cursor = "pointer";
    ctrl.addEventListener("click", function () {
      var p = currentParams();
      var idx = SORTS.map(function (x) { return x.key; }).indexOf(p.sort || "real_avg");
      p.sort = SORTS[(idx + 1) % SORTS.length].key;
      p.page = null;
      pushParams(p);
      load();
    });
  }

  // Descriptive rule (PO 2026-07-22): no fake-share verdict on creators. Reword the «bot-corrected»
  // header, hide the fraud pill + the «Макс. доля фейков» filter block. Platform chips are now WIRED
  // (SA-2 footprint index, see wirePlatform); only the TOPIC chips stay deferred (no game taxonomy yet).
  function stripAndDefer() {
    setText(document, "H Sub", "База креаторов · ранжирование по реальной аудитории Twitch");
    hide(q(document, "Fraud Pill"));                    // toolbar «Фейки ≤ 10%» pill
    hide(q(document, "Fraud Box"));                     // whole sidebar «FRAUD-DETECTION / Pro / Quality index» scoring panel (fake-share + quality-index filters — no fraud verdict on creators)
    hide(q(document, "Sec · Бюджет за интеграцию, ₽")); // integration-price filter — no pricing model
    Array.prototype.slice.call(document.querySelectorAll('[data-pencil-name^="Chip · "]')).forEach(function (n) {
      if (PLATFORM_CHIPS[n.getAttribute("data-pencil-name")] != null) return; // platform chip → wired, not deferred
      n.style.opacity = "0.4";
      n.style.pointerEvents = "none";
      n.title = "Скоро";
    });
  }

  function chipSelected(node, on) {
    if (!node) return;
    node.style.backgroundColor = on ? "#1E1838" : "";
    node.style.borderColor = on ? "#7B5CFA" : "";
  }

  // Single-select platform filter → the `platform` API param (backed by channel_social_links).
  function wirePlatform() {
    var active = currentParams().platform || null;
    Object.keys(PLATFORM_CHIPS).forEach(function (anchor) {
      var node = q(document, anchor);
      if (!node) return;
      var value = PLATFORM_CHIPS[anchor];
      chipSelected(node, active === value);
      node.style.cursor = "pointer";
      node.addEventListener("click", function () {
        var p = currentParams();
        p.platform = p.platform === value ? null : value; // toggle (single-select)
        p.page = null;
        pushParams(p);
        Object.keys(PLATFORM_CHIPS).forEach(function (a) { chipSelected(q(document, a), PLATFORM_CHIPS[a] === p.platform); });
        load();
      });
    });
  }

  function boot() {
    if (!captureTemplate()) return; // markup changed — fail safe, leave the design as-is
    wireSort();
    stripAndDefer();
    wirePlatform();
    load();
  }

  fetch("/api/v1/lk/status", { headers: { Accept: "application/json" }, credentials: "same-origin" })
    .then(function (r) { return r.ok ? r.json() : {}; })
    .then(function (s) {
      if (!s || !s.authenticated) { window.location.href = "/login"; return; }
      boot();
    })
    .catch(function () { window.location.href = "/login"; });
})();
