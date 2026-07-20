// Viewer discover «Куда пойти» (screen 04) — wires REAL live-now channels ranked by real audience
// (GET /api/v1/discover/live: live streams + latest TIH, viewer-free) into the faithful Pencil
// export. Auth-gated: /api/v1/lk/status → /login. The default grid = ALL live channels (that's what
// the header describes); the «Подписки» tab filters to the user's watched channels (real count);
// «Рекомендации» is deferred (no rec engine — never faked); «Watchlists» navigates to /app/watchlists.
// Preview panel shows the real subset of the design (live/viewers/game/name/reliability + a real
// add-to-watchlist Save); moment / chat-activity / chat-mood have no source → hidden. CSP-safe.
(function () {
  "use strict";

  var LABEL_COLOR = { green: "#25D9A4", yellow: "#F5C451", red: "#F0616D" };

  function q(root, name) { return (root || document).querySelector('[data-pencil-name="' + name + '"]'); }
  function qa(root, sel) { return Array.prototype.slice.call((root || document).querySelectorAll(sel)); }
  function qp(root, prefix) { return (root || document).querySelector('[data-pencil-name^="' + prefix + '"]'); }
  function setP(root, prefix, t) { var n = qp(root, prefix); if (n != null && t != null) n.textContent = t; }
  function setT(root, name, t) { var n = q(root, name); if (n != null && t != null) n.textContent = t; }
  function hide(el) { if (el) el.style.display = "none"; }
  function dim(el, title) { if (el) { el.style.opacity = "0.45"; el.style.pointerEvents = "none"; if (title) el.title = title; } }
  function fmt(n) {
    if (n == null || isNaN(n)) return "—";
    return Math.round(n).toString().replace(/\B(?=(\d{3})+(?!\d))/g, " ");
  }
  function initials(s) { s = (s || "").replace(/[^A-Za-zА-Яа-я0-9]/g, ""); return (s.slice(0, 1) || "?").toUpperCase(); }
  function colorOf(c) { return LABEL_COLOR[c.erv_label_color] || "#9A9AA9"; }
  function uptime(startedAt) {
    if (!startedAt) return "";
    var mins = Math.max(0, Math.floor((Date.now() - new Date(startedAt).getTime()) / 60000));
    var h = Math.floor(mins / 60), m = mins % 60;
    return "в эфире " + h + ":" + (m < 10 ? "0" : "") + m;
  }

  var HEADERS = { Accept: "application/json", "Accept-Language": "ru" };
  function apiGet(p) {
    return fetch(p, { headers: HEADERS, credentials: "same-origin" })
      .then(function (r) { return r.ok ? r.json() : Promise.reject(r.status); });
  }

  var T = {};
  var all = [];        // full live list (ranked by real)
  var filterWatched = false;

  function capture() {
    var card = document.querySelector('[data-pencil-name^="Card · "]');
    var row = document.querySelector('[data-pencil-name^="Grid Row"]');
    var grid = q(document, "Channel Grid");
    if (!card || !row || !grid) return false;
    T.card = card.cloneNode(true);
    T.card.style.border = "1px solid #25252F"; // neutral border (the design highlights its 1st sample)
    T.row = row.cloneNode(false);
    T.grid = grid;
    return true;
  }

  function buildCard(c) {
    var card = T.card.cloneNode(true);
    card.setAttribute("data-pencil-name", "Card · " + c.login);
    setP(card, "Vw T", fmt(c.shown_viewers));
    setP(card, "Game T", c.game_name || "—");
    setP(card, "Av T", initials(c.display_name || c.login));
    setP(card, "Chan Name", c.display_name || c.login);
    setP(card, "Chan Up", uptime(c.started_at));
    setP(card, "Real Num", fmt(c.real_viewers));
    var num = qp(card, "Real Num"); if (num) num.style.color = colorOf(c);
    setP(card, "Real Pct", c.erv_percent != null ? "· " + Math.round(c.erv_percent) + "%" : "");
    var label = q(card, "Label");
    if (label) { label.textContent = c.erv_label || "—"; label.style.color = colorOf(c); }
    var dot = q(card, "Dot"); if (dot) dot.style.backgroundColor = colorOf(c);
    card.style.cursor = "pointer";
    card.addEventListener("mouseenter", function () { renderPreview(c); });
    card.addEventListener("click", function () { window.location.href = "/c/" + encodeURIComponent(c.login); });
    return card;
  }

  function renderGrid() {
    var list = filterWatched ? all.filter(function (c) { return c.is_watched_by_user; }) : all;
    qa(T.grid, '[data-pencil-name^="Grid Row"]').forEach(function (n) { n.remove(); });
    qa(T.grid, '[data-pencil-name="EmptyNote"]').forEach(function (n) { n.remove(); });
    if (!list.length) {
      var d = document.createElement("div");
      d.setAttribute("data-pencil-name", "EmptyNote");
      d.style.cssText = "padding:36px 8px;color:#5E5E6B;font-family:Inter,system-ui,sans-serif;font-size:14px;";
      d.textContent = filterWatched
        ? "Из ваших списков сейчас никто не в эфире."
        : "Сейчас никто не в эфире — загляните позже.";
      T.grid.appendChild(d);
      return;
    }
    var row = null;
    list.forEach(function (c, i) {
      if (i % 2 === 0) { row = T.row.cloneNode(false); row.setAttribute("data-pencil-name", "Grid Row " + (Math.floor(i / 2) + 1)); T.grid.appendChild(row); }
      row.appendChild(buildCard(c));
    });
    if (list.length) renderPreview(list[0]);
  }

  // ---- preview panel (real subset; no-source sections hidden) ----
  function renderPreview(c) {
    setP(document, "PV Vw T", fmt(c.shown_viewers));
    setP(document, "PV Game T", c.game_name || "—");
    setP(document, "PV Av T", initials(c.display_name || c.login));
    setP(document, "PV Chan Name", c.display_name || c.login);
    setP(document, "PV Chan Foll", c.is_watched_by_user ? "в вашем watchlist" : uptime(c.started_at));
    setP(document, "PV Rel Num", fmt(c.real_viewers) + (c.erv_percent != null ? " · " + Math.round(c.erv_percent) + "%" : ""));
    var pvTrust = q(document, "PV Trust");
    if (pvTrust) {
      var lbl = q(pvTrust, "Label"); if (lbl) { lbl.textContent = c.erv_label || "—"; lbl.style.color = colorOf(c); }
      var dt = q(pvTrust, "Dot"); if (dt) dt.style.backgroundColor = colorOf(c);
    }
    var watch = q(document, "PV Watch");
    if (watch) {
      watch.style.cursor = "pointer";
      watch.onclick = function () { window.open("https://twitch.tv/" + encodeURIComponent(c.login), "_blank", "noopener"); };
    }
    var save = q(document, "PV Save");
    if (save) {
      save.style.cursor = "pointer";
      save.title = "Добавить в watchlist";
      save.onclick = function () { saveToWatchlist(c, save); };
    }
  }

  function saveToWatchlist(c, btn) {
    apiGet("/api/v1/watchlists")
      .then(function (resp) {
        var first = ((resp && resp.data) || [])[0];
        if (!first) throw 404;
        return fetch("/api/v1/watchlists/" + first.id + "/channels", {
          method: "POST",
          headers: { Accept: "application/json", "Content-Type": "application/json" },
          credentials: "same-origin",
          body: JSON.stringify({ login: c.login }),
        });
      })
      .then(function (r) {
        btn.title = r && (r.ok || r.status === 422) ? "В watchlist ✓" : "Не удалось";
        btn.style.opacity = "0.6";
        c.is_watched_by_user = true;
      })
      .catch(function () { btn.title = "Не удалось"; });
  }

  // ---- tabs ----
  function wireTabs() {
    var subs = q(document, "Tab · Подписки");
    var recs = q(document, "Tab · Рекомендации");
    var wl = q(document, "Tab · Watchlists");
    var activeClass = subs && subs.className;
    var inactiveClass = recs && recs.className;
    // the grid defaults to ALL live (what the header describes) → start with no filter active
    if (subs && inactiveClass) subs.className = inactiveClass;

    if (subs) {
      subs.style.cursor = "pointer";
      subs.addEventListener("click", function () {
        filterWatched = !filterWatched;
        if (activeClass && inactiveClass) subs.className = filterWatched ? activeClass : inactiveClass;
        renderGrid();
      });
    }
    if (recs) dim(recs, "Скоро — персональные рекомендации");
    if (wl) {
      wl.style.cursor = "pointer";
      wl.addEventListener("click", function () { window.location.href = "/app/watchlists"; });
    }
    // real tab counts
    apiGet("/api/v1/watchlists").then(function (resp) {
      setP(document, "Tab Count T · Watchlists", String(((resp && resp.data) || []).length));
    }).catch(function () {});
  }

  function hideNoSourceSections() {
    hide(qp(document, "PV Sec · МОМЕНТ ИГРЫ"));
    hide(qp(document, "PV Sec · АКТИВНОСТЬ ЧАТА"));
    hide(qp(document, "PV Sec · НАСТРОЕНИЕ ЧАТА"));
    dim(q(document, "Sort Btn"), "Скоро"); // ranking is fixed to real audience for now
  }

  // ---- boot ----
  function boot() {
    if (!capture()) return;
    hideNoSourceSections();
    wireTabs();
    apiGet("/api/v1/discover/live")
      .then(function (resp) {
        all = (resp && resp.data) || [];
        setT(document, "H2 Sub", "Сейчас в эфире — кого посмотреть прямо сейчас · " +
          all.length + " " + plural(all.length, "канал", "канала", "каналов") + " онлайн");
        setP(document, "Tab Count T · Подписки", String(all.filter(function (c) { return c.is_watched_by_user; }).length));
        renderGrid();
      })
      .catch(function () {
        setT(document, "H2 Sub", "Не удалось загрузить эфиры — попробуйте позже.");
      });
  }

  function plural(n, one, few, many) {
    n = Math.abs(n) % 100; var n1 = n % 10;
    if (n > 10 && n < 20) return many;
    if (n1 > 1 && n1 < 5) return few;
    if (n1 === 1) return one;
    return many;
  }

  fetch("/api/v1/lk/status", { headers: { Accept: "application/json" }, credentials: "same-origin" })
    .then(function (r) { return r.ok ? r.json() : {}; })
    .then(function (s) {
      if (!s || !s.authenticated) { window.location.href = "/login"; return; }
      boot();
    })
    .catch(function () { window.location.href = "/login"; });
})();
