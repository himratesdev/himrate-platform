// Viewer watchlists (screen 05) — wires the viewer's REAL saved lists + channels into the faithful
// Pencil export, and the core mutations (create list / add channel / remove channel). Auth-gated:
// /api/v1/lk/status (httpOnly cookie) → /login when unauthenticated. Data + writes over
// /api/v1/watchlists(/:id/channels) (same-origin cookie; API mode = no CSRF token, SameSite=Lax
// cookie blocks cross-site POST). Each channel headline = TI/ERV (same as the public card). No mocks.
// Mutations: create/rename/delete list, add/remove/move channel, tag+note editing (prompt/confirm UI —
// CSP-safe). Deferred (no design affordance / not in the headline contract): notification toggle,
// trend arrow, sort menu, Premium filters. CSP-safe, no eval.
(function () {
  "use strict";

  // Host-mapping (2026-09): links must stay in the path scheme the page was served under
  // (canonical short paths on app.himrate.com, /app-prefixed on staging/dev). Local fallback —
  // page scripts load BEFORE brand_nav.js, so window.hrAppPath may not exist yet.
  var hrApp = window.hrAppPath || function (p) { var pre = (location.pathname === "/app" || location.pathname.indexOf("/app/") === 0) ? "/app" : ""; return pre + p; };

  var LABEL_COLOR = { green: "#25D9A4", yellow: "#F5C451", red: "#F0616D", grey: "#9A9AA9", amber: "#F6A823" };
  var DOT_PALETTE = ["#7B5CFA", "#4FA9FF", "#25D9A4", "#F6A823", "#FB4E55"];

  function q(root, name) { return (root || document).querySelector('[data-pencil-name="' + name + '"]'); }
  function qp(root, prefix) { return (root || document).querySelector('[data-pencil-name^="' + prefix + '"]'); }
  function setP(root, prefix, text) { var n = qp(root, prefix); if (n != null && text != null) n.textContent = text; }
  function hideP(root, prefix) { var n = qp(root, prefix); if (n) n.style.display = "none"; }
  function fmt(n) {
    if (n == null || isNaN(n)) return "—";
    return Math.round(n).toString().replace(/\B(?=(\d{3})+(?!\d))/g, " ");
  }
  function initials(s) { s = (s || "").replace(/[^A-Za-zА-Яа-я0-9]/g, ""); return (s.slice(0, 1) || "?").toUpperCase(); }
  // Flat v2 shape: {erv (native count), authenticity, band_color (green|yellow|red|grey|amber)}.
  function colorOf(c) { return (c && LABEL_COLOR[c.band_color]) || "#9A9AA9"; }
  function pctOf(c) { return c == null ? null : c.authenticity; }
  function realOf(c) { return c ? c.erv : null; }
  // Legal-safe ERV label derived from erv% (the endpoint gives only the colour) — canonical band thresholds.
  function ervLabel(p) {
    if (p == null) return "—";
    if (p >= 90) return "Аудитория реальная";
    if (p >= 80) return "Аномалий не замечено";
    if (p >= 50) return "Аномалия онлайна";
    return "Значительная аномалия онлайна";
  }
  // v2 rows: label from the ENGINE band (5 colors incl. amber/grey) so text can't contradict the
  // dot; % thresholds serve only v1 rows (CR n5).
  function bandLabelRu(color) {
    return { green: "Аномалий не замечено", yellow: "Аномалия онлайна", red: "Значительная аномалия онлайна",
             grey: "Недостаточно данных", amber: "Онлайн выше наблюдаемой активности" }[color] || null;
  }

  var API = "/api/v1/watchlists";
  var JSON_HEADERS = { Accept: "application/json", "Content-Type": "application/json", "Accept-Language": "ru" };
  function apiGet(path) { return fetch(API + path, { headers: JSON_HEADERS, credentials: "same-origin" }).then(okJson); }
  function apiSend(method, path, body) {
    return fetch(API + path, { method: method, headers: JSON_HEADERS, credentials: "same-origin", body: body ? JSON.stringify(body) : undefined }).then(okJson);
  }
  function okJson(r) { if (!r.ok) return r.json().then(function (e) { throw e; }); return r.json(); }

  var T = {};
  var state = { lists: [], activeId: null };

  function capture() {
    var listItem = document.querySelector('[data-pencil-name^="WL · "]');
    var row = document.querySelector('[data-pencil-name^="WL Row · "]');
    var listsPanel = q(document, "Lists Panel");
    var table = q(document, "WL Table");
    if (!listItem || !row || !listsPanel || !table) return false;
    T.listItem = listItem.cloneNode(true);
    T.row = row.cloneNode(true);
    T.listsPanel = listsPanel;
    T.table = table;
    T.emptyState = q(document, "WL Empty State");
    if (T.emptyState) { T.emptyStateNode = T.emptyState.cloneNode(true); T.emptyState.remove(); }
    return true;
  }

  // ---- lists panel ----
  // Sample clean-up lives in its own helpers so the error branch strips the design mock too.
  function clearListItems() {
    Array.prototype.slice.call(T.listsPanel.querySelectorAll('[data-pencil-name^="WL · "]')).forEach(function (n) { n.remove(); });
  }
  function clearChannelRows() {
    Array.prototype.slice.call(T.table.querySelectorAll('[data-pencil-name^="WL Row · "]')).forEach(function (n) { n.remove(); });
    var oldEmpty = q(document, "WL Empty State"); if (oldEmpty) oldEmpty.remove();
  }

  function renderLists() {
    // remove sample list items; keep the head + the "Создать список" add row
    clearListItems();
    var addRow = q(T.listsPanel, "Lists Add");
    var listsDiv = q(T.listsPanel, "Lists Div");
    var anchorBefore = listsDiv || addRow; // insert items before the divider/add-row
    setP(T.listsPanel, "Lists Head N", String(state.lists.length));

    state.lists.forEach(function (wl, i) {
      var item = T.listItem.cloneNode(true);
      item.setAttribute("data-pencil-name", "WL · " + wl.id);
      setP(item, "WL Name", wl.name);
      setP(item, "WL Cnt T", String(wl.channels_count != null ? wl.channels_count : (wl.stats && wl.stats.total) || 0));
      var dot = qp(item, "WL Dot"); if (dot) dot.style.backgroundColor = DOT_PALETTE[i % DOT_PALETTE.length];
      item.style.backgroundColor = wl.id === state.activeId ? "#19152E" : "";
      item.style.cursor = "pointer";
      item.addEventListener("click", function () { selectList(wl.id); });
      if (anchorBefore) T.listsPanel.insertBefore(item, anchorBefore); else T.listsPanel.appendChild(item);
    });

    if (addRow) {
      addRow.style.cursor = "pointer";
      if (!addRow.__wired) { addRow.__wired = true; addRow.addEventListener("click", createList); }
    }
  }

  function selectList(id) {
    state.activeId = id;
    // repaint active state
    Array.prototype.slice.call(T.listsPanel.querySelectorAll('[data-pencil-name^="WL · "]')).forEach(function (n) {
      n.style.backgroundColor = n.getAttribute("data-pencil-name") === "WL · " + id ? "#19152E" : "";
    });
    loadChannels(id);
  }

  // ---- channels table ----
  function loadChannels(id) {
    apiGet("/" + id + "/channels?sort=erv_desc")
      .then(function (d) { renderChannels((d && d.data) || [], (d && d.meta) || {}); })
      .catch(function () { renderChannels([], {}); });
  }

  function renderChannels(channels, meta) {
    // toolbar title/meta
    var wl = state.lists.filter(function (l) { return l.id === state.activeId; })[0];
    setP(document, "TB Title", (wl && wl.name) || meta.watchlist_name || "Список");
    setP(document, "TB Meta T", (meta.total != null ? meta.total : channels.length) + " " + plural(meta.total || channels.length, "канал", "канала", "каналов"));

    // clear existing rows + any empty-state
    clearChannelRows();
    wireAddChannel();
    wireListControls();

    if (!channels.length) { T.table.style.display = "none"; renderEmpty(wl); return; }

    T.table.style.display = "";
    channels.forEach(function (c) { T.table.appendChild(buildRow(c)); });
  }

  function buildRow(c) {
    var col = colorOf(c);
    var row = T.row.cloneNode(true);
    row.setAttribute("data-pencil-name", "WL Row · " + c.login);
    setP(row, "WC Av T", initials(c.display_name || c.login));
    setP(row, "WC Name · ", c.display_name || c.login); // " · " separator — avoid matching "WC Name Row · …"
    if (!c.is_live) hideP(row, "WC Live");
    // category / game isn't in the contract → show live/handle status instead
    setP(row, "WC Game", c.is_live ? "В эфире" : "twitch.tv/" + c.login);
    setP(row, "WC Real Num", fmt(realOf(c)));
    var real = qp(row, "WC Real Num"); if (real) real.style.color = col;
    hideP(row, "WC Trend"); // no trend field in the contract

    // trust badge (derived ERV label + colour); dot is the badge's first small child
    var label = q(row, "Label");
    if (label) { label.textContent = (c.band_color && bandLabelRu(c.band_color)) || ervLabel(pctOf(c)); label.style.color = col; }
    var badge = qp(row, "WC Badge");
    if (badge) { var bdot = badge.querySelector("div"); if (bdot) bdot.style.backgroundColor = col; }

    // tags / notes (read-only) — hide when absent
    var tag = (c.tags && c.tags[0]) || null;
    if (tag) setP(row, "WC Chip T", tag); else hideP(row, "WC Chip");
    if (c.notes) setP(row, "WC Note", "«" + c.notes + "»"); else { hideP(row, "WC Note"); hideP(row, "WC AddNote"); }

    // notification toggle — deferred (no write endpoint wired); leave visual, not interactive.
    var bell = qp(row, "WC Bell"); if (bell) bell.style.pointerEvents = "none";

    // inject the row controls (the design has none): edit note/tag, move, remove.
    injectRowAction(row, "✎", "Заметка и тег", function () { editChannelMeta(c); });
    injectRowAction(row, "⇄", "Переместить в другой список", function () { moveChannel(c); });
    injectRowAction(row, "✕", "Убрать из списка", function () { removeChannel(c); }, true);

    // row click → public channel card
    row.style.cursor = "pointer";
    row.addEventListener("click", function (e) {
      if (e.target.closest("[data-hr-act]") || e.target.closest('[data-pencil-name^="WC Bell"]')) return;
      window.location.href = "/c/" + encodeURIComponent(c.login);
    });
    return row;
  }

  function injectRowAction(row, glyph, title, onClick, danger) {
    var x = document.createElement("div");
    x.setAttribute("data-hr-act", glyph);
    x.textContent = glyph;
    x.title = title;
    x.style.cssText = "margin-left:6px;width:22px;height:22px;flex:none;display:flex;align-items:center;justify-content:center;" +
      "border-radius:999px;color:#5E5E6B;cursor:pointer;font-size:12px;font-family:Inter,system-ui,sans-serif;";
    var hoverColor = danger ? "#FB4E55" : "#7B5CFA";
    var hoverBg = danger ? "#2C1316" : "#19152E";
    x.addEventListener("mouseenter", function () { x.style.color = hoverColor; x.style.background = hoverBg; });
    x.addEventListener("mouseleave", function () { x.style.color = "#5E5E6B"; x.style.background = "transparent"; });
    x.addEventListener("click", function (e) {
      e.stopPropagation();
      onClick();
    });
    row.appendChild(x);
  }

  function renderEmpty(wl) {
    if (!T.emptyStateNode) return;
    var empty = T.emptyStateNode.cloneNode(true);
    setP(empty, "ES Tag T", "СПИСОК «" + ((wl && wl.name) || "").toUpperCase() + "»");
    var primary = q(empty, "ES Primary");
    if (primary) { primary.style.cursor = "pointer"; primary.addEventListener("click", function () { window.location.href = hrApp("/search"); }); }
    var secondary = q(empty, "ES Secondary"); if (secondary) secondary.style.display = "none"; // import = deferred
    T.table.parentNode.insertBefore(empty, T.table.nextSibling);
  }

  // ---- mutations ----
  function createList() {
    var name = window.prompt("Название нового списка:");
    if (!name || !name.trim()) return;
    apiSend("POST", "", { watchlist: { name: name.trim() } })
      .then(function () { return reloadLists(); })
      .catch(function (e) { alert(errMsg(e, "Не удалось создать список")); });
  }

  function wireAddChannel() {
    var btn = q(document, "Add Channel");
    if (!btn || btn.__wired) return;
    btn.__wired = true;
    btn.style.cursor = "pointer";
    btn.addEventListener("click", function () {
      if (!state.activeId) return;
      var login = window.prompt("Логин канала на Twitch:");
      if (!login || !login.trim()) return;
      apiSend("POST", "/" + state.activeId + "/channels", { channel_login: login.trim().toLowerCase() })
        .then(function () { return refreshActive(); })
        .catch(function (e) { alert(errMsg(e, "Не удалось добавить канал")); });
    });
  }

  function removeChannel(c) {
    var cid = c.channel_id || c.id;
    if (!state.activeId || !cid) return;
    apiSend("DELETE", "/" + state.activeId + "/channels/" + cid)
      .then(function () { return refreshActive(); })
      .catch(function (e) { alert(errMsg(e, "Не удалось убрать канал")); });
  }

  // PATCH /watchlists/:list_id/channels/:id/meta {notes, tags: []} — edit the row's note + tag.
  function editChannelMeta(c) {
    var cid = c.channel_id || c.id;
    if (!state.activeId || !cid) return;
    var notes = window.prompt("Заметка к каналу (пусто — убрать):", c.notes || "");
    if (notes == null) return; // cancelled
    var tag = window.prompt("Тег (пусто — без тега):", (c.tags && c.tags[0]) || "");
    if (tag == null) return; // cancelled
    apiSend("PATCH", "/" + state.activeId + "/channels/" + cid + "/meta",
      { notes: notes.trim(), tags: tag.trim() ? [tag.trim()] : [] })
      .then(function () { return refreshActive(); })
      .catch(function (e) { alert(errMsg(e, "Не удалось сохранить заметку")); });
  }

  // PATCH /watchlists/:list_id/channels/:id/move {target_watchlist_id} — move to another list.
  function moveChannel(c) {
    var cid = c.channel_id || c.id;
    if (!state.activeId || !cid) return;
    var others = state.lists.filter(function (l) { return l.id !== state.activeId; });
    if (!others.length) { alert("Нет другого списка — сначала создайте его."); return; }
    var listing = others.map(function (l, i) { return (i + 1) + ". " + l.name; }).join("\n");
    var raw = window.prompt("Переместить в список — введите номер:\n" + listing);
    if (raw == null) return;
    var target = others[parseInt(raw, 10) - 1];
    if (!target) { alert("Нет списка с таким номером."); return; }
    apiSend("PATCH", "/" + state.activeId + "/channels/" + cid + "/move", { target_watchlist_id: target.id })
      .then(function () { return refreshActive(); })
      .catch(function (e) { alert(errMsg(e, "Не удалось переместить канал")); });
  }

  // Toolbar controls for the ACTIVE list (rename / delete) — the design has no affordance, so two
  // small controls are injected before the sort control, styled like the row actions.
  function wireListControls() {
    var host = q(document, "TB Right") || q(document, "WL Toolbar");
    if (!host || host.__hrListCtl) return;
    host.__hrListCtl = true;
    var anchor = q(host, "Sort Ctl");
    [
      { glyph: "✎", title: "Переименовать список", fn: renameList, danger: false },
      { glyph: "🗑", title: "Удалить список", fn: deleteList, danger: true },
    ].forEach(function (a) {
      var x = document.createElement("div");
      x.setAttribute("data-hr-act", a.glyph);
      x.textContent = a.glyph;
      x.title = a.title;
      x.style.cssText = "width:28px;height:28px;flex:none;display:flex;align-items:center;justify-content:center;" +
        "border-radius:8px;border:1px solid #25252F;color:#9A9AA9;cursor:pointer;font-size:13px;font-family:Inter,system-ui,sans-serif;";
      var hoverColor = a.danger ? "#FB4E55" : "#7B5CFA";
      x.addEventListener("mouseenter", function () { x.style.color = hoverColor; x.style.borderColor = hoverColor; });
      x.addEventListener("mouseleave", function () { x.style.color = "#9A9AA9"; x.style.borderColor = "#25252F"; });
      x.addEventListener("click", a.fn);
      if (anchor) host.insertBefore(x, anchor); else host.appendChild(x);
    });
  }

  // PATCH /watchlists/:id {watchlist: {name}} — rename the active list.
  function renameList() {
    var wl = state.lists.filter(function (l) { return l.id === state.activeId; })[0];
    if (!wl) return;
    var name = window.prompt("Новое название списка:", wl.name);
    if (!name || !name.trim() || name.trim() === wl.name) return;
    apiSend("PATCH", "/" + wl.id, { watchlist: { name: name.trim() } })
      .then(function () { return reloadLists(); })
      .catch(function (e) { alert(errMsg(e, "Не удалось переименовать список")); });
  }

  // DELETE /watchlists/:id — delete the active list (backend auto-recreates a default if it was last).
  function deleteList() {
    var wl = state.lists.filter(function (l) { return l.id === state.activeId; })[0];
    if (!wl) return;
    if (!window.confirm("Удалить список «" + wl.name + "»? Каналы будут убраны из него.")) return;
    apiSend("DELETE", "/" + wl.id)
      .then(function () { return reloadLists(); })
      .catch(function (e) { alert(errMsg(e, "Не удалось удалить список")); });
  }

  function reloadLists() {
    return apiGet("").then(function (d) {
      state.lists = (d && d.data) || [];
      if (!state.lists.some(function (l) { return l.id === state.activeId; })) state.activeId = state.lists[0] && state.lists[0].id;
      renderLists();
      if (state.activeId) loadChannels(state.activeId);
    });
  }
  function refreshActive() { return reloadLists(); }

  function errMsg(e, fallback) { return (e && (e.message || (e.error && e.error.message))) || fallback; }
  function plural(n, one, few, many) {
    n = Math.abs(n) % 100; var n1 = n % 10;
    if (n > 10 && n < 20) return many;
    if (n1 > 1 && n1 < 5) return few;
    if (n1 === 1) return one;
    return many;
  }

  // Honest error state: strip the design's sample lists/rows and say the load failed — the mock
  // («8 каналов · 4 в эфире», sample lists) must not survive a failed API call.
  function renderLoadError() {
    if (!T.listsPanel || !T.table) return;
    clearListItems();
    clearChannelRows();
    setP(T.listsPanel, "Lists Head N", "—");
    setP(document, "TB Title", "Списки");
    setP(document, "TB Meta T", "—");
    T.table.style.display = "none";
    var note = document.createElement("div");
    note.setAttribute("data-pencil-name", "WL Empty State");
    note.style.cssText = "padding:28px 8px;color:#5E5E6B;font-family:Inter,system-ui,sans-serif;font-size:14px;";
    note.textContent = "Не удалось загрузить списки — попробуйте позже.";
    T.table.parentNode.insertBefore(note, T.table.nextSibling);
  }

  // ---- boot ----
  function boot() {
    if (!capture()) return;
    apiGet("").then(function (d) {
      state.lists = (d && d.data) || [];
      state.activeId = state.lists[0] && state.lists[0].id;
      renderLists();
      if (state.activeId) loadChannels(state.activeId); else renderChannels([], {});
    }).catch(renderLoadError);
  }

  // Auth gate: ONLY the lk/status probe (and its own network failure) decides the /login redirect.
  // Data/boot errors render the honest error state instead of bouncing the user to /login.
  fetch("/api/v1/lk/status", { headers: { Accept: "application/json" }, credentials: "same-origin" })
    .then(function (r) { return r.ok ? r.json() : {}; })
    .then(
      function (s) {
        if (!s || !s.authenticated) { window.location.href = "/login"; return; }
        try { boot(); } catch (e) { renderLoadError(); }
      },
      function () { window.location.href = "/login"; }
    );
})();
