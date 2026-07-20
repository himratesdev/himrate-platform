// Streamer grow (screen 13) — wires REAL game opportunities into the faithful Pencil export.
// Auth-gated: /api/v1/lk/status → /login. Data: GET /api/v1/discover/games — the PO-spec engine
// (Steam novelty ∧ few streamers (7-12 band) ∧ distributed viewers), worker-warmed cache; on a
// cold cache the endpoint reports pending and this page re-polls until the list is ready.
// Goal banner: the streamer's REAL current real-viewers (own card headline) vs the «100» goal;
// hidden when no Twitch is linked. Honest deferrals: per-game stability badge (no per-game
// stability source) hidden; Genre badge hidden (not in the payload). CSP-safe, no eval.
(function () {
  "use strict";

  function q(root, name) { return (root || document).querySelector('[data-pencil-name="' + name + '"]'); }
  function qa(root, sel) { return Array.prototype.slice.call((root || document).querySelectorAll(sel)); }
  function qp(root, prefix) { return (root || document).querySelector('[data-pencil-name^="' + prefix + '"]'); }
  function setP(root, prefix, t) { var n = qp(root, prefix); if (n != null && t != null) n.textContent = t; }
  function setT(root, name, t) { var n = q(root, name); if (n != null && t != null) n.textContent = t; }
  function hide(el) { if (el) el.style.display = "none"; }
  function fmt(n) {
    if (n == null || isNaN(n)) return "—";
    return Math.round(n).toString().replace(/\B(?=(\d{3})+(?!\d))/g, " ");
  }

  var HEADERS = { Accept: "application/json", "Accept-Language": "ru" };
  function apiGet(p) {
    return fetch(p, { headers: HEADERS, credentials: "same-origin" })
      .then(function (r) { return r.ok ? r.json() : Promise.reject(r.status); });
  }

  var T = {};
  function capture() {
    var card = document.querySelector('[data-pencil-name^="Game · "]');
    var row = document.querySelector('[data-pencil-name^="Game Row"]');
    if (!card || !row) return false;
    T.card = card.cloneNode(true);
    T.row = row.cloneNode(false);
    T.rowParent = row.parentNode;
    return true;
  }

  function metric(card, name, valueText, fillPct) {
    var wrap = q(card, "M " + name);
    if (!wrap) return;
    setP(wrap, "M V", valueText);
    var fill = qp(wrap, "M Fill");
    if (fill) fill.style.width = Math.max(2, Math.min(100, fillPct || 0)) + "%";
  }

  function buildCard(g) {
    var card = T.card.cloneNode(true);
    card.setAttribute("data-pencil-name", "Game · " + g.name);
    setT(card, "Cov Title", g.name);
    setP(card, "NB T", "Новинка в Steam"); // true by construction — the pool IS Steam new releases
    hide(q(card, "Genre"));                 // no genre in the payload — never fake
    setP(card, "SD T", "Спрос: " + fmt(g.total_ccv) + " зрителей");
    setP(card, "SS T", "Стримеров: " + g.live_streamers);

    metric(card, "Спрос", fmt(g.total_ccv), (g.demand_score || 0) * 100);
    metric(card, "Конкуренция", String(g.live_streamers), Math.min(100, g.live_streamers));
    metric(card, "Потенциал роста", Math.round((g.growth_score || 0) * 100) + "%", (g.growth_score || 0) * 100);

    hide(q(card, "Rel Wrap")); // per-game stability has no source — deferred
    var cta = qp(card, "CTA");
    if (cta) {
      cta.style.cursor = "pointer";
      cta.addEventListener("click", function () {
        window.open("https://www.twitch.tv/directory/category/" + encodeURIComponent(g.name.toLowerCase().replace(/[^a-z0-9]+/g, "-")), "_blank", "noopener");
      });
    }
    card.title = "top-1 канал забирает " + (g.top1_share_pct != null ? g.top1_share_pct + "%" : "—") + " зрителей категории";
    return card;
  }

  function renderGames(games) {
    qa(T.rowParent, '[data-pencil-name^="Game Row"]').forEach(function (n) { n.remove(); });
    qa(T.rowParent, '[data-pencil-name="EmptyNote"]').forEach(function (n) { n.remove(); });
    if (!games.length) {
      var d = document.createElement("div");
      d.setAttribute("data-pencil-name", "EmptyNote");
      d.style.cssText = "padding:28px 8px;color:#5E5E6B;font-family:Inter,system-ui,sans-serif;font-size:14px;";
      d.textContent = "Подходящих игр сейчас не нашлось — новинки Steam ещё не обжиты на Twitch. Загляните позже.";
      T.rowParent.appendChild(d);
      return;
    }
    var row = null;
    games.forEach(function (g, i) {
      if (i % 2 === 0) { row = T.row.cloneNode(false); row.setAttribute("data-pencil-name", "Game Row " + (Math.floor(i / 2) + 1)); T.rowParent.appendChild(row); }
      row.appendChild(buildCard(g));
    });
  }

  function renderPendingNote() {
    qa(T.rowParent, '[data-pencil-name^="Game Row"]').forEach(function (n) { n.remove(); });
    if (q(document, "EmptyNote")) return;
    var d = document.createElement("div");
    d.setAttribute("data-pencil-name", "EmptyNote");
    d.style.cssText = "padding:28px 8px;color:#9A9AA9;font-family:Inter,system-ui,sans-serif;font-size:14px;";
    d.textContent = "Считаем возможности по свежим данным Steam и Twitch — меньше минуты…";
    T.rowParent.appendChild(d);
  }

  // Goal banner — real current REAL viewers of the streamer's own channel vs the 100 goal.
  function renderGoal() {
    apiGet("/api/v1/user/me")
      .then(function (resp) {
        var u = (resp && resp.data) || {};
        if (!u.twitch_login) { hide(q(document, "Goal Banner")); return Promise.reject("done"); }
        return apiGet("/api/v1/channels/" + encodeURIComponent(u.twitch_login) + "/card");
      })
      .then(function (card) {
        var hl = card && card.data && card.data.layers && card.data.layers.headline && card.data.layers.headline.data || {};
        if (hl.erv_count == null) { hide(q(document, "Goal Banner")); return; }
        setT(document, "GP Now N", fmt(hl.erv_count));
        var fill = q(document, "GP Fill");
        if (fill) fill.style.width = Math.max(2, Math.min(100, (hl.erv_count / 100) * 100)) + "%";
      })
      .catch(function (e) { if (e !== "done") hide(q(document, "Goal Banner")); });
  }

  var pollTimer;
  function load() {
    apiGet("/api/v1/discover/games")
      .then(function (resp) {
        var d = (resp && resp.data) || {};
        clearTimeout(pollTimer);
        if (d.status === "pending") { renderPendingNote(); pollTimer = setTimeout(load, 6000); return; }
        renderGames(d.games || []);
      })
      .catch(function () { renderGames([]); });
  }

  function boot() {
    if (!capture()) return;
    renderGoal();
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
