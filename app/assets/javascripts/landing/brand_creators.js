// Brand creator discovery (screen 60) — wires REAL ranked data into the faithful Pencil export,
// REUSING the existing brand streamer search (GET /api/v1/brand/streamers/search — real 30-day audience
// over trends_daily_aggregates, already scale-correct to ~10k channels; NO new backend). The result
// card opens the cross-platform blogger profile (screen 61, /app/blogger/:login). Auth-gated:
// /api/v1/lk/status → /login; non-brand role → in-page brand paywall before any data request
// (403 stays as insurance).
//
// Twitch-anchored + descriptive (PO 2026-07-22): the design's social-platform / topic filter chips need
// a footprint index / taxonomy → deferred (dimmed, «Скоро»); per-card «фейки N%», «480K ₽» price
// forecast, social «ER», the per-card social-platform icons, and the «shield» fraud pill are stripped
// (no fraud verdict). Real: name, reputation label, topic (Twitch game), real audience (Twitch ERV).
// The real filters (category/language/min_real/classification/sort/page) stay URL-drivable. CSP-safe:
// external asset, same-origin fetch, textContent (no eval / no innerHTML on user data).
(function () {
  "use strict";

  // Channel search — the surface promises "поиск", but the design ships only filters: there was no
  // way to look a streamer up by name. Mounted ABOVE the results block as a sibling: the results
  // container itself is rebuilt on every load, so anything placed inside it gets wiped.
  // Idempotent — re-running after a re-render just reuses the existing slot.
  function mountChannelSearch() {
    if (!window.hrMountSearch) return;
    if (document.querySelector('[data-pencil-name="Search Slot"]')) return;
    var anchor = q(document, "Results") || q(document, "Grid") || q(document, "TB Left");
    if (!anchor || !anchor.parentNode) return;
    var slot = document.createElement("div");
    slot.setAttribute("data-pencil-name", "Search Slot");
    slot.style.cssText = "margin:0 0 14px;width:100%;";
    anchor.parentNode.insertBefore(slot, anchor);
    window.hrMountSearch({
      mount: slot,
      placeholder: "Поиск блогера: ник, Telegram, YouTube…",
      onPick: function (row) { window.location.href = hrApp("/blogger/" + encodeURIComponent(row.login)); }
    });
  }

  // Host-mapping (2026-09): links must stay in the path scheme the page was served under
  // (canonical short paths on app.himrate.com, /app-prefixed on staging/dev). Local fallback —
  // page scripts load BEFORE brand_nav.js, so window.hrAppPath may not exist yet.
  var hrApp = window.hrAppPath || function (p) { var pre = (location.pathname === "/app" || location.pathname.indexOf("/app/") === 0) ? "/app" : ""; return pre + p; };

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
    var openTo = hrApp("/blogger/" + encodeURIComponent(s.login));
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
    renderLoadMore(data, base, results.length);
  }

  // Real pagination for the design's baked "Показать ещё 24 блогера / Показаны 1–8 из 248" block:
  // real range + remaining count from the API's page/per_page/total; hidden when the last page is shown.
  var loadMoreWired = false;
  function renderLoadMore(data, base, count) {
    var block = q(document, "Load More");
    if (!block) return;
    var total = data.total || 0;
    var shownEnd = base + count;
    if (shownEnd >= total) { block.style.display = "none"; return; }
    block.style.display = "";
    var next = Math.min(data.per_page || count, total - shownEnd);
    setText(document, "Load More T",
      "Показать ещё " + next + " " + plural(next, "блогера", "блогера", "блогеров"));
    setText(document, "Load More Count", "Показаны " + (base + 1) + "–" + shownEnd + " из " + fmt(total));
    var btn = q(document, "Load More Btn");
    if (btn && !loadMoreWired) {
      loadMoreWired = true;
      btn.style.cursor = "pointer";
      btn.addEventListener("click", function () {
        var p = currentParams();
        p.page = String((parseInt(p.page, 10) || 1) + 1);
        pushParams(p);
        load();
      });
    }
  }

  function hideLoadMore() {
    var block = q(document, "Load More");
    if (block) block.style.display = "none";
  }

  function renderEmpty(msg) {
    var box = document.createElement("div");
    box.setAttribute("data-pencil-name", "Empty");
    box.style.cssText = "width:100%;padding:48px 16px;text-align:center;color:#9A9AA9;font-family:Inter,system-ui,sans-serif;font-size:15px;";
    box.textContent = msg;
    clearCards();
    grid.appendChild(box);
    hideLoadMore();
  }

  function renderPaywall() {
    var box = document.createElement("div");
    box.setAttribute("data-pencil-name", "Paywall");
    box.style.cssText = "width:100%;padding:48px 20px;text-align:center;color:#C7C7D1;font-family:Inter,system-ui,sans-serif;";
    box.innerHTML =
      '<div style="font-size:18px;font-weight:700;margin-bottom:8px;">Поиск креаторов — для бренд-аккаунтов</div>' +
      '<div style="font-size:14px;color:#9A9AA9;max-width:460px;margin:0 auto 20px;">Ранжирование по реальной аудитории доступно на бизнес-тарифе. Подключите бренд-доступ, чтобы искать креаторов и открывать их кросс-платформенные профили.</div>' +
      '<a href="/brands" style="display:inline-block;background:#7B5CFA;color:#fff;text-decoration:none;padding:11px 20px;border-radius:12px;font-weight:600;font-size:14px;">Узнать о бренд-тарифах</a>' +
      '<div style="margin-top:12px;"><a href="' + ((window.location.pathname.indexOf("/app/") === 0 || window.location.pathname === "/app") ? "/app" : "") + '/business/new" style="font-size:13px;color:#9A9AA9;text-decoration:underline;">Создать бизнес-учётку →</a></div>';
    clearCards();
    grid.appendChild(box);
    setText(document, "TB Found", "");
    hideLoadMore();
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
    // Geo / demographics / ER filter sections have no API backing (search params: category, language,
    // platform, min_real, frequency, classification, sort, page) → dim like the topic chips and blank
    // their baked demo values («Россия», «Москва, СПб +3», «25–34 (ядро)») — no fake filter state.
    ["Sec · Гео", "Sec · Демография", "Sec · Вовлечённость (ER)"].forEach(function (a) {
      var n = q(document, a);
      if (n) { n.style.opacity = "0.4"; n.style.pointerEvents = "none"; n.title = "Скоро"; }
    });
    ["SelV · Страна", "SelV · Город", "SelV · Возраст"].forEach(function (a) { setText(document, a, "—"); });
    setText(document, "LRb · ER", "—");            // baked «от 4.0%» value of the dimmed ER slider
    hide(q(document, "Rail Count"));               // baked «23 параметра» badge — no honest live count
    setText(document, "Apply T", "Показать");      // baked «Показать 248 блогеров» — no number upfront
    var apply = q(document, "Apply Btn");
    if (apply) {
      apply.style.cursor = "pointer";
      apply.addEventListener("click", function () { load(); }); // re-run the search with current params
    }
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

  // Brand endpoints are gated on the brand role (business tier / active business-team — mirrors
  // BrandStreamerSearchPolicy). lk/status carries `roles`, so non-brand users get the paywall
  // up-front, without firing a doomed data request. The in-load 403 path stays as insurance.
  function isBrand(s) { return ((s && s.roles) || []).indexOf("brand") !== -1; }

  function boot(brandOk) {
    if (!captureTemplate()) return; // markup changed — fail safe, leave the design as-is
    stripAndDefer();
    if (!brandOk) { renderPaywall(); return; } // pre-request paywall for non-brand users
    wireSort();
    wirePlatform();
    load();
  }

  // Only the lk/status outcome decides the /login redirect; any later boot/data error surfaces
  // in-page (renderEmpty) — an authenticated user must never be bounced to /login by a data failure.
  fetch("/api/v1/lk/status", { headers: { Accept: "application/json" }, credentials: "same-origin" })
    .then(function (r) { return r.ok ? r.json() : {}; })
    .catch(function () { return null; })
    .then(function (s) {
      if (!s || !s.authenticated) { window.location.href = "/login"; return; }
      try {
        boot(isBrand(s));
      } catch (e) {
        if (window.console) console.warn("[brand_creators] boot failed:", e);
        if (grid) {
          setText(document, "TB Found", "—");
          renderEmpty("Не удалось загрузить — попробуйте позже.");
        }
      }
    });
})();
