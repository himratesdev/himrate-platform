// Brand dashboard streamer search (screen 20) — wires REAL ranked data into the faithful Pencil
// export. Auth-gated: checks /api/v1/lk/status (httpOnly session cookie); unauthenticated → /login,
// non-brand (403) → in-page upgrade prompt. Results come from the brand-gated
// GET /api/v1/brand/streamers/search (real 30-day audience over trends_daily_aggregates, no mocks).
//
// Scope (working page, additive): results grid + count are fully real; Sort (click-cycles the 3 real
// sorts) and the frequency chips are functional filters; every backend-supported filter
// (category/language/min_real/classification/frequency/sort/page) is also drivable via URL query, so
// deep links work today and richer custom-widget filter UIs land additively (no rework). Filters with
// no engine backing (format/platforms/budget/reliability-band/save-search/compare-select) are disabled
// honestly — mirrors the API's own `deferred` list. CSP-safe: external asset, same-origin fetch, no eval.
(function () {
  "use strict";

  // ---- config ----
  var API = "/api/v1/brand/streamers/search";
  // ti_avg → colour band, kept in lockstep with the ERV label the API returns (both derive from ti).
  function tiColor(ti) {
    if (ti == null || isNaN(ti)) return "#9A9AA9";
    if (ti >= 80) return "#25D9A4"; // green — real / no anomalies
    if (ti >= 50) return "#F5C451"; // yellow — anomaly
    return "#F0616D"; // red — significant anomaly
  }
  // Sort click-cycle: three real sorts the API supports.
  var SORTS = [
    { key: "real_avg", label: "Реальные зрители" },
    { key: "real_pct", label: "% реальных" },
    { key: "streams_per_week", label: "Частота эфиров" },
  ];
  // frequency chip anchor → API frequency bucket key.
  var FREQ_CHIPS = {
    "Chip · Ежедневно": "daily",
    "Chip · 3–5 / нед": "3_5",
    "Chip · 1–2 / нед": "1_2",
  };
  // Deferred filter/action controls (no engine backing yet) — disabled so they don't look broken.
  var DEFERRED_ANCHORS = [
    "Chip · Стрим", "Chip · Интеграция", "Chip · Преролл", "Chip · Спонсор-сегмент",
    "Check · Twitch", "Check · YouTube", "Check · Telegram", "Check · VK Play",
    "Check · Безупречная", "Check · Стабильная", "Check · Изменчивая", "Check · Нестабильная",
    "Btn · Сохранить поиск",
  ];
  // Compare/overlap selection (feeds /app/compare + /app/overlap, both take 2-4 channels).
  var MAX_SELECT = 4;
  var selected = [];
  function isSelected(login) { return selected.indexOf(login) !== -1; }

  // ---- dom helpers ----
  function q(root, name) {
    return (root || document).querySelector('[data-pencil-name="' + name + '"]');
  }
  function setText(root, name, text) {
    var n = q(root, name);
    if (n != null && text != null) n.textContent = text;
  }
  function hide(root, name) {
    var n = q(root, name);
    if (n) n.style.display = "none";
  }
  function fmt(n) {
    if (n == null || isNaN(n)) return "—";
    return Math.round(n).toString().replace(/\B(?=(\d{3})+(?!\d))/g, " ");
  }
  function initials(name) {
    if (!name) return "?";
    var s = name.replace(/[^A-Za-zА-Яа-я0-9]/g, "");
    return (s.slice(0, 2) || "?").toUpperCase();
  }
  function freqLabel(spw) {
    if (spw == null) return null;
    if (spw >= 7) return "ежедневно";
    if (spw >= 3) return "3–5 / нед";
    return "1–2 / нед";
  }

  // ---- url <-> state ----
  function currentParams() {
    var u = new URLSearchParams(window.location.search);
    var p = {};
    ["category", "language", "min_real", "frequency", "classification", "sort", "page"].forEach(function (k) {
      if (u.get(k)) p[k] = u.get(k);
    });
    if (!p.sort) p.sort = "real_avg";
    return p;
  }
  function pushParams(p) {
    var u = new URLSearchParams();
    Object.keys(p).forEach(function (k) {
      if (p[k] != null && p[k] !== "") u.set(k, p[k]);
    });
    var qs = u.toString();
    window.history.replaceState(null, "", qs ? "?" + qs : window.location.pathname);
  }

  // ---- results grid ----
  var grid, cardTemplate, rowTemplate;

  function captureTemplates() {
    var firstCard = document.querySelector('[data-pencil-name^="Card · "]');
    var firstRow = q(document, "Grid Row");
    if (!firstCard || !firstRow) return false;
    // Grid Rows are direct children of `Results`, which ALSO holds the toolbar (count/sort) as its
    // first child — so we clear only the row/empty/paywall nodes, never the toolbar.
    grid = firstRow.parentNode;

    cardTemplate = firstCard.cloneNode(true);
    // We are Twitch-only — drop non-Twitch platform badges from the template so no clone fakes them.
    Array.prototype.slice
      .call(cardTemplate.querySelectorAll('[data-pencil-name^="Plat · "]'))
      .forEach(function (node) {
        if (node.getAttribute("data-pencil-name") !== "Plat · Twitch") node.remove();
      });
    // No rate-card in the engine → hide the integration price; drop the legally-loaded "точно не бот"
    // verified badge (the classification label carries the trust signal, legal-safe).
    hide(cardTemplate, "Price");
    hide(cardTemplate, "Verified");

    rowTemplate = firstRow.cloneNode(false); // empty flex row, keeps the grid-row classes
    return true;
  }

  // Remove only the result rows + any injected empty/paywall block; keep the toolbar intact.
  function clearRows() {
    Array.prototype.slice
      .call(grid.querySelectorAll('[data-pencil-name="Grid Row"], [data-pencil-name="Empty"], [data-pencil-name="Paywall"]'))
      .forEach(function (n) { n.remove(); });
  }

  function buildCard(s) {
    var card = cardTemplate.cloneNode(true);
    card.setAttribute("data-pencil-name", "Card · " + s.login);

    setText(card, "Av T", initials(s.display_name || s.login));
    setText(card, "Name", s.display_name || s.login);
    setText(card, "Handle", "twitch.tv/" + s.login);

    // Trust badge — canonical ERV label (legal-safe) + colour from ti band.
    var color = tiColor(s.ti_avg);
    if (s.classification_label) setText(card, "TB Label", s.classification_label);
    var tbLabel = q(card, "TB Label");
    if (tbLabel) tbLabel.style.color = color;
    var tbDot = q(card, "TB Dot");
    if (tbDot) tbDot.style.backgroundColor = color;

    // Headline — real vs shown viewers.
    setText(card, "Real", fmt(s.real_avg_viewers));
    var realNode = q(card, "Real");
    if (realNode) realNode.style.color = color;
    setText(card, "Shown", "из " + fmt(s.shown_avg_viewers) + " показано");

    // Delta — audience-correction %. Hide when there is effectively no correction.
    // Legal-safe wording (v3 doctrine, matches channel_card.js): neutral "от показанных",
    // never "накрутка" as a public accusation about a searched streamer.
    var corr = s.bot_correction_pct == null ? null : Math.abs(s.bot_correction_pct);
    if (corr == null || corr < 1) {
      hide(card, "Delta");
    } else {
      setText(card, "DT", "−" + Math.round(corr) + "% от показанных");
    }

    // Reality bar — real % of shown.
    var fill = q(card, "RS Fill");
    if (fill) fill.style.width = (s.real_pct != null ? Math.max(0, Math.min(100, s.real_pct)) : 0) + "%";

    // Meta line: game · frequency · language.
    var meta = [s.category, freqLabel(s.streams_per_week), s.language && s.language.toUpperCase()]
      .filter(Boolean)
      .join(" · ");
    setText(card, "Meta", meta || "—");
    setText(card, "PT", "Twitch");

    // Open → brand streamer card (screen 21) — the brand's 30-day verification deep view (live now).
    var open = q(card, "Open");
    if (open) {
      open.style.cursor = "pointer";
      open.addEventListener("click", function () {
        window.location.href = "/app/streamers/" + encodeURIComponent(s.login);
      });
    }
    // Whole card is also a click target for discoverability.
    card.style.cursor = "pointer";
    card.addEventListener("click", function (e) {
      if (e.target.closest('[data-pencil-name="Open"]')) return;
      if (e.target.closest("[data-hr-select]")) return;
      window.location.href = "/app/streamers/" + encodeURIComponent(s.login);
    });

    // Selection pill — pick 2-4 streamers, then compare / overlap them. Injected into the footer's
    // left (the price slot is hidden), next to "Open" — a natural action row, no overlap with the badge.
    var toggle = document.createElement("div");
    toggle.setAttribute("data-hr-select", s.login);
    toggle.style.cssText = "display:inline-flex;align-items:center;gap:6px;padding:6px 11px;border-radius:999px;" +
      "cursor:pointer;font-size:12px;font-weight:600;line-height:1;font-family:Inter,system-ui,sans-serif;" +
      "transition:background .12s,border-color .12s,color .12s;user-select:none;";
    paintToggle(toggle, isSelected(s.login));
    toggle.addEventListener("click", function (e) {
      e.stopPropagation();
      if (!isSelected(s.login) && selected.length >= MAX_SELECT) return; // cap at 4
      toggleSelect(s.login);
      paintToggle(toggle, isSelected(s.login));
      updateActionBar();
    });
    var footer = q(card, "Footer");
    if (footer) footer.insertBefore(toggle, footer.firstChild); else card.appendChild(toggle);
    return card;
  }

  function paintToggle(el, on) {
    el.style.background = on ? "#7B5CFA" : "transparent";
    el.style.border = on ? "1px solid #7B5CFA" : "1px solid #3A3A46";
    el.style.color = on ? "#fff" : "#9A9AA9";
    el.textContent = on ? "✓ В сравнении" : "+ Сравнить";
  }

  function toggleSelect(login) {
    var i = selected.indexOf(login);
    if (i !== -1) selected.splice(i, 1);
    else if (selected.length < MAX_SELECT) selected.push(login);
  }

  function renderResults(data) {
    var results = (data && data.results) || [];
    setText(document, "RT Count", fmt(data.total) + " " + plural(data.total, "стример", "стримера", "стримеров"));
    setText(document, "RT Note", "ранжировано по реальным зрителям");

    // Reflect active sort in the control label.
    var active = SORTS.filter(function (x) { return x.key === (data.sort || "real_avg"); })[0] || SORTS[0];
    setText(document, "Sort T", active.label);

    // Rebuild the grid — 2 cards per Grid Row (design layout). Toolbar is preserved.
    clearRows();
    if (!results.length) {
      renderEmpty("Ничего не найдено. Смягчите фильтры.");
      return;
    }
    var row = null;
    results.forEach(function (s, i) {
      if (i % 2 === 0) {
        row = rowTemplate.cloneNode(false);
        grid.appendChild(row);
      }
      row.appendChild(buildCard(s));
    });
  }

  function renderEmpty(msg) {
    var box = document.createElement("div");
    box.setAttribute("data-pencil-name", "Empty");
    box.style.cssText = "width:100%;padding:48px 16px;text-align:center;color:#9A9AA9;font-family:Inter,system-ui,sans-serif;font-size:15px;";
    box.textContent = msg;
    clearRows();
    grid.appendChild(box);
  }

  function plural(n, one, few, many) {
    n = Math.abs(n) % 100;
    var n1 = n % 10;
    if (n > 10 && n < 20) return many;
    if (n1 > 1 && n1 < 5) return few;
    if (n1 === 1) return one;
    return many;
  }

  // ---- fetch ----
  function load() {
    var p = currentParams();
    var u = new URLSearchParams(p);
    fetch(API + "?" + u.toString(), {
      headers: { Accept: "application/json", "Accept-Language": "ru" },
      credentials: "same-origin",
    })
      .then(function (r) {
        if (r.status === 403) { renderPaywall(); return null; }
        if (!r.ok) throw new Error("HTTP " + r.status);
        return r.json();
      })
      .then(function (d) { if (d) renderResults(d); })
      .catch(function (e) {
        if (window.console) console.warn("[brand_search] load failed:", e);
        setText(document, "RT Count", "—");
        renderEmpty("Не удалось загрузить результаты. Попробуйте позже.");
      });
  }

  function renderPaywall() {
    var box = document.createElement("div");
    box.setAttribute("data-pencil-name", "Paywall");
    box.style.cssText = "width:100%;padding:48px 20px;text-align:center;color:#C7C7D1;font-family:Inter,system-ui,sans-serif;";
    box.innerHTML =
      '<div style="font-size:18px;font-weight:700;margin-bottom:8px;">Поиск стримеров — для бренд-аккаунтов</div>' +
      '<div style="font-size:14px;color:#9A9AA9;max-width:460px;margin:0 auto 20px;">Ранжирование по реальной аудитории доступно на бизнес-тарифе. Подключите бренд-доступ, чтобы искать и сравнивать стримеров.</div>' +
      '<a href="/brands" style="display:inline-block;background:#7B5CFA;color:#fff;text-decoration:none;padding:11px 20px;border-radius:12px;font-weight:600;font-size:14px;">Узнать о бренд-тарифах</a>';
    clearRows();
    grid.appendChild(box);
    setText(document, "RT Count", "");
  }

  // ---- filter interactivity (functional subset) ----
  function wireSort() {
    var ctrl = q(document, "Sort");
    if (!ctrl) return;
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

  function chipSelected(node, on) {
    if (!node) return;
    node.style.backgroundColor = on ? "#1E1838" : "#1C1C24";
    node.style.borderColor = on ? "#7B5CFA" : "#25252F";
  }

  function wireFrequency() {
    var active = currentParams().frequency || null;
    Object.keys(FREQ_CHIPS).forEach(function (anchor) {
      var node = q(document, anchor);
      if (!node) return;
      var bucket = FREQ_CHIPS[anchor];
      chipSelected(node, active === bucket);
      node.style.cursor = "pointer";
      node.addEventListener("click", function () {
        var p = currentParams();
        p.frequency = p.frequency === bucket ? null : bucket; // toggle
        p.page = null;
        pushParams(p);
        Object.keys(FREQ_CHIPS).forEach(function (a) {
          chipSelected(q(document, a), FREQ_CHIPS[a] === p.frequency);
        });
        load();
      });
    });
  }

  function disableDeferred() {
    DEFERRED_ANCHORS.forEach(function (anchor) {
      var n = q(document, anchor);
      if (n) {
        n.style.opacity = "0.4";
        n.style.pointerEvents = "none";
        n.title = "Скоро";
      }
    });
  }

  // ---- selection action bar (Compare / Overlap of the picked streamers) ----
  var overlapBtn = null;
  function wireSelection() {
    var cmp = q(document, "Btn · Сравнить выбранных");
    if (!cmp) return;
    // Handlers read `selected` live; a click with <2 picked is a no-op (bar stays dimmed).
    cmp.addEventListener("click", function () {
      if (selected.length >= 2) window.location.href = "/app/compare?channels=" + selected.map(encodeURIComponent).join(",");
    });
    // Inject a sibling "Пересечение" action (overlap has no sidebar entry — this is its way in).
    overlapBtn = cmp.cloneNode(true);
    overlapBtn.setAttribute("data-pencil-name", "Btn · Пересечение выбранных");
    overlapBtn.addEventListener("click", function () {
      if (selected.length >= 2) window.location.href = "/app/overlap?channels=" + selected.map(encodeURIComponent).join(",");
    });
    cmp.parentNode.insertBefore(overlapBtn, cmp.nextSibling);
    updateActionBar();
  }

  function setBtn(btn, label, enabled) {
    if (!btn) return;
    // Update the deepest text node so we keep the design's icon/structure.
    var textNode = deepestTextHolder(btn);
    if (textNode) textNode.textContent = label; else btn.textContent = label;
    btn.style.opacity = enabled ? "1" : "0.4";
    btn.style.pointerEvents = enabled ? "auto" : "none";
    btn.style.cursor = enabled ? "pointer" : "default";
  }

  function deepestTextHolder(el) {
    // The button's visible label is its last element child that has non-whitespace text.
    var kids = el.querySelectorAll("*");
    for (var i = kids.length - 1; i >= 0; i--) {
      if (kids[i].children.length === 0 && kids[i].textContent.trim()) return kids[i];
    }
    return null;
  }

  function updateActionBar() {
    var n = selected.length;
    var ready = n >= 2;
    setBtn(q(document, "Btn · Сравнить выбранных"), ready ? "Сравнить (" + n + ")" : "Сравнить выбранных", ready);
    setBtn(overlapBtn, ready ? "Пересечение (" + n + ")" : "Пересечение аудиторий", ready);
  }

  // ---- boot: auth gate then load ----
  function boot() {
    if (!captureTemplates()) return; // markup changed — fail safe, leave design as-is
    wireSort();
    wireFrequency();
    wireSelection();
    disableDeferred();
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
