// Brand dashboard compare (screen 23) — wires REAL side-by-side data into the faithful Pencil export.
// Auth-gated: checks /api/v1/lk/status (httpOnly session cookie); unauthenticated → /login, non-brand
// (403) → in-page upgrade prompt. Compared channels come from the URL (?channels=a,b,c&prices=…, in
// order); data from the brand-gated GET /api/v1/brand/compare (real 30-day audience, no mocks).
//
// The design is a metrics×streamers table with 3 sample columns; we render 2-4 real columns by cloning
// the header/slot/row-cell templates. Winner cells are greened from the API's `best_in_row`. Rows with
// no engine backing (Охват аудитории/unique_reach, ERV·вовлечённость/engagement_rate) are hidden —
// mirrors the API's `deferred` list; nothing faked. CSP-safe: external asset, same-origin fetch, no eval.
(function () {
  "use strict";

  var API = "/api/v1/brand/compare";
  var GREEN = "#25D9A4";
  var DEFAULT_TXT = "#F4F4F7";
  var WIN_BG = "#10271F";
  // reputation band → dot/label colour (design palette).
  var BAND_COLOR = { impeccable: "#25D9A4", stable: "#4FA9FF", variable: "#F6A823", unstable: "#FB4E55" };
  var REASON_RU = { lowest_price_per_real_viewer_recommendable_band: "самый выгодный за реального зрителя" };

  // ---- dom helpers ----
  function q(root, name) { return (root || document).querySelector('[data-pencil-name="' + name + '"]'); }
  function qa(root, name) {
    return Array.prototype.slice.call((root || document).querySelectorAll('[data-pencil-name="' + name + '"]'));
  }
  function setText(root, name, t) { var n = q(root, name); if (n != null && t != null) n.textContent = t; }
  function hide(el) { if (el) el.style.display = "none"; }
  function fmt(n) {
    if (n == null || isNaN(n)) return "—";
    return Math.round(n).toString().replace(/\B(?=(\d{3})+(?!\d))/g, " ");
  }
  function initials(s) { s = (s || "").replace(/[^A-Za-zА-Яа-я0-9]/g, ""); return (s.slice(0, 1) || "?").toUpperCase(); }

  // ---- url params ----
  function channelsParam() {
    return (new URLSearchParams(location.search).get("channels") || "")
      .split(",").map(function (s) { return s.trim(); }).filter(Boolean);
  }
  function pricesParam() { return new URLSearchParams(location.search).get("prices") || ""; }

  // ---- row metric definitions ----
  // kind: "value" (V T text + best_in_row winner), "band" (Rel badge), min (winner = lowest client-side)
  var ROWS = [
    { anchor: "Row · Реальные зрители", get: function (c) { return c.audience.real_avg_viewers; }, f: fmt, bestKey: "real_avg_viewers" },
    { anchor: "Row · Надёжность", kind: "band" },
    { anchor: "Row · Доля реальных", get: function (c) { return c.audience.real_pct; }, f: function (v) { return v == null ? "—" : Math.round(v) + "%"; }, bestKey: "real_pct" },
    { anchor: "Row · Охват аудитории", deferred: true },
    { anchor: "Row · ERV · вовлечённость", deferred: true },
    { anchor: "Row · Частота эфиров", get: function (c) { return c.audience.streams_per_week; }, f: function (v) { return v == null ? "—" : (Math.round(v * 10) / 10) + " / нед"; }, bestKey: "streams_per_week" },
    { anchor: "Row · Цена интеграции", get: function (c) { return c.price && c.price.per_integration; }, f: function (v) { return v == null ? "—" : "₽" + fmt(v); }, bestMin: true },
    { anchor: "Row · Цена за реального зрителя", get: function (c) { return c.price && c.price.per_real_viewer; }, f: function (v) { return v == null ? "—" : "₽" + (Math.round(v * 10) / 10); }, bestKey: "price_per_real_viewer" },
  ];

  // ---- templates (captured before the DOM is rebuilt) ----
  var T = {};
  function capture() {
    var head = document.querySelector('[data-pencil-name^="Head · "]');
    var slot = document.querySelector('[data-pencil-name^="Slot · "]:not([data-pencil-name="Slot · Добавить"])');
    var bestI = q(document, "Best I");
    if (!head || !slot) return false;
    T.head = head.cloneNode(true);
    T.slot = slot.cloneNode(true);
    T.bestI = bestI ? bestI.cloneNode(true) : null;

    // Per-row neutral cell template (strip any winner styling so clones start clean).
    T.cells = {};
    ROWS.forEach(function (r) {
      if (r.deferred) return;
      var row = q(document, r.anchor);
      var cell = row && q(row, "V");
      if (!cell) return;
      var tpl = cell.cloneNode(true);
      qa(tpl, "Best I").forEach(function (n) { n.remove(); });
      tpl.style.backgroundColor = "transparent";
      var vt = q(tpl, "V T");
      if (vt) vt.style.color = DEFAULT_TXT;
      T.cells[r.anchor] = tpl;
    });
    return true;
  }

  // Remove every child of `container` whose data-pencil-name starts with `prefix`.
  function removeByPrefix(container, prefix) {
    Array.prototype.slice
      .call(container.querySelectorAll('[data-pencil-name^="' + prefix + '"]'))
      .forEach(function (n) { n.remove(); });
  }

  // ---- render ----
  function render(data) {
    var channels = (data && data.channels) || [];
    var best = data.best_in_row || {};

    renderSlots(channels);
    renderHeader(channels);
    renderRows(channels, best);
    renderRecommendation(data.recommendation);
  }

  function renderSlots(channels) {
    var slots = q(document, "Slots");
    var addBtn = q(document, "Slot · Добавить");
    // remove existing streamer slots (keep the Add button)
    Array.prototype.slice.call(slots.querySelectorAll('[data-pencil-name^="Slot · "]')).forEach(function (n) {
      if (n.getAttribute("data-pencil-name") !== "Slot · Добавить") n.remove();
    });
    channels.forEach(function (c) {
      var s = T.slot.cloneNode(true);
      s.setAttribute("data-pencil-name", "Slot · " + c.login);
      setText(s, "Av T", initials(c.display_name || c.login));
      setText(s, "Name", c.display_name || c.login);
      setText(s, "G T", c.category || "—");
      var rm = q(s, "Remove");
      if (rm) {
        rm.style.cursor = "pointer";
        rm.addEventListener("click", function (e) { e.stopPropagation(); removeChannel(c.login); });
      }
      if (addBtn) slots.insertBefore(s, addBtn); else slots.appendChild(s);
    });
    if (addBtn) {
      addBtn.style.cursor = "pointer";
      addBtn.addEventListener("click", function () { location.href = "/app/search"; });
    }
  }

  function renderHeader(channels) {
    var headerRow = q(document, "Header Row");
    removeByPrefix(headerRow, "Head · "); // headers have unique per-login names
    channels.forEach(function (c) {
      var h = T.head.cloneNode(true);
      h.setAttribute("data-pencil-name", "Head · " + c.login);
      setText(h, "Av T", initials(c.display_name || c.login));
      setText(h, "N", c.display_name || c.login);
      setText(h, "H", "@" + c.login + (c.category ? " · " + c.category : ""));
      var a = c.audience || {};
      setText(h, "RV", fmt(a.real_avg_viewers));
      setText(h, "Shown", "показано " + fmt(a.shown_avg_viewers));
      headerRow.appendChild(h);
    });
  }

  function renderRows(channels, best) {
    ROWS.forEach(function (r) {
      var row = q(document, r.anchor);
      if (!row) return;
      if (r.deferred) { hide(row); return; }
      var tpl = T.cells[r.anchor];
      if (!tpl) return;

      qa(row, "V").forEach(function (n) { n.remove(); });

      // winner login for this row
      var winner = null;
      if (r.kind !== "band") {
        if (r.bestKey) winner = best[r.bestKey];
        else if (r.bestMin) winner = minLogin(channels, r.get);
      }

      channels.forEach(function (c) {
        var cell = tpl.cloneNode(true);
        if (r.kind === "band") {
          fillBand(cell, c);
        } else {
          var v = r.get(c);
          setText(cell, "V T", r.f(v));
          applyWinner(cell, winner != null && c.login === winner);
        }
        row.appendChild(cell);
      });
    });
  }

  function fillBand(cell, c) {
    var rep = c.reputation || {};
    setText(cell, "Rel Label", rep.band_label_ru || "—");
    var color = BAND_COLOR[rep.band] || "#9A9AA9";
    var lbl = q(cell, "Rel Label");
    if (lbl) lbl.style.color = color;
    var dot = q(cell, "Rel Dot");
    if (dot) dot.style.backgroundColor = color;
  }

  function applyWinner(cell, isWinner) {
    qa(cell, "Best I").forEach(function (n) { n.remove(); });
    var vt = q(cell, "V T");
    if (isWinner) {
      cell.style.backgroundColor = WIN_BG;
      if (vt) vt.style.color = GREEN;
      if (T.bestI) cell.insertBefore(T.bestI.cloneNode(true), cell.firstChild);
    } else {
      cell.style.backgroundColor = "transparent";
      if (vt) vt.style.color = DEFAULT_TXT;
    }
  }

  function minLogin(channels, getter) {
    var best = null, bestV = Infinity;
    channels.forEach(function (c) {
      var v = getter(c);
      if (v != null && !isNaN(v) && v < bestV) { bestV = v; best = c.login; }
    });
    return best;
  }

  function renderRecommendation(rec) {
    var block = q(document, "Recommendation");
    if (!block) return;
    if (!rec) { hide(block); return; }
    var reason = REASON_RU[rec.reason] || "лучший выбор";
    setText(document, "Rec T", "Рекомендация: " + rec.login + " — " + reason);
    setText(document, "Rec S", rec.per_real_viewer != null
      ? "₽" + (Math.round(rec.per_real_viewer * 10) / 10) + " за реального зрителя при надёжной репутации."
      : "Оптимальное соотношение цены и реальной аудитории.");
    setText(document, "Rec Pill T", "Лучшая цена");
  }

  // ---- interactivity ----
  function removeChannel(login) {
    var rest = channelsParam().filter(function (l) { return l.toLowerCase() !== login.toLowerCase(); });
    var u = new URLSearchParams();
    if (rest.length) u.set("channels", rest.join(","));
    location.href = rest.length ? "/app/compare?" + u.toString() : "/app/compare";
  }

  function disableDeferred() {
    ["Btn · Экспорт", "Period"].forEach(function (a) {
      var n = q(document, a);
      if (n) { n.style.opacity = "0.4"; n.style.pointerEvents = "none"; n.title = "Скоро"; }
    });
    var add = q(document, "Btn · Добавить стримера");
    if (add) { add.style.cursor = "pointer"; add.addEventListener("click", function () { location.href = "/app/search"; }); }
  }

  // ---- states ----
  function fullScreenMsg(html) {
    var content = q(document, "Content") || document.body;
    var box = document.createElement("div");
    box.setAttribute("data-pencil-name", "MsgState");
    box.style.cssText = "width:100%;padding:64px 20px;text-align:center;color:#C7C7D1;font-family:Inter,system-ui,sans-serif;";
    box.innerHTML = html;
    // hide the table + recommendation + slots, show the message
    [q(document, "Compare Table"), q(document, "Recommendation"), q(document, "Slots")].forEach(hide);
    var existing = q(document, "MsgState");
    if (existing) existing.remove();
    content.appendChild(box);
  }

  function renderPrompt() {
    fullScreenMsg(
      '<div style="font-size:18px;font-weight:700;margin-bottom:8px;">Сравнение стримеров</div>' +
      '<div style="font-size:14px;color:#9A9AA9;max-width:460px;margin:0 auto 20px;">Выберите 2–4 стримеров, чтобы сравнить их по реальной аудитории, надёжности и цене за реального зрителя.</div>' +
      '<a href="/app/search" style="display:inline-block;background:#7B5CFA;color:#fff;text-decoration:none;padding:11px 20px;border-radius:12px;font-weight:600;font-size:14px;">Найти стримеров</a>'
    );
  }

  function renderPaywall() {
    fullScreenMsg(
      '<div style="font-size:18px;font-weight:700;margin-bottom:8px;">Сравнение — для бренд-аккаунтов</div>' +
      '<div style="font-size:14px;color:#9A9AA9;max-width:460px;margin:0 auto 20px;">Сравнение стримеров по реальной аудитории доступно на бизнес-тарифе.</div>' +
      '<a href="/brands" style="display:inline-block;background:#7B5CFA;color:#fff;text-decoration:none;padding:11px 20px;border-radius:12px;font-weight:600;font-size:14px;">Узнать о бренд-тарифах</a>'
    );
  }

  // ---- boot ----
  function load() {
    var channels = channelsParam();
    if (channels.length < 2) { renderPrompt(); return; }
    var u = new URLSearchParams();
    u.set("channels", channels.join(","));
    if (pricesParam()) u.set("prices", pricesParam());
    fetch(API + "?" + u.toString(), {
      headers: { Accept: "application/json", "Accept-Language": "ru" },
      credentials: "same-origin",
    })
      .then(function (r) {
        if (r.status === 403) { renderPaywall(); return null; }
        if (r.status === 404) { renderPrompt(); return null; }
        if (!r.ok) throw new Error("HTTP " + r.status);
        return r.json();
      })
      .then(function (d) { if (d) render(d); })
      .catch(function (e) {
        if (window.console) console.warn("[brand_compare] load failed:", e);
        fullScreenMsg('<div style="font-size:15px;color:#9A9AA9;">Не удалось загрузить сравнение. Попробуйте позже.</div>');
      });
  }

  function boot() {
    if (!capture()) return; // markup changed — fail safe
    disableDeferred();
    load();
  }

  fetch("/api/v1/lk/status", { headers: { Accept: "application/json" }, credentials: "same-origin" })
    .then(function (r) { return r.ok ? r.json() : {}; })
    .then(function (s) {
      if (!s || !s.authenticated) { location.href = "/login"; return; }
      boot();
    })
    .catch(function () { location.href = "/login"; });
})();
