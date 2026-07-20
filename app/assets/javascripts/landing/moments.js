// Viewer best-moments (screen 07) — wires REAL chat-peak moments + window clips into the faithful
// Pencil export. Auth-gated: /api/v1/lk/status → /login. Data: GET /api/v1/me/moments?login=X
// (chat peaks from the CH per-minute MV; clips from the Helix worker-cache, matched by vod_offset).
// Channel: ?login= param → else the user's own twitch_login → else their first recent channel.
//
// Honest deferrals (backend SCOPING 2026-07-21): AI categories (Клатчи/Смешное/Хайлайты) and
// «Донаты» have no engine/source → those filter chips are dimmed; per-moment transcript needs a
// clip transcript (paid Whisper per clip) → section hidden; Shorts/Share export deferred.
// CSP-safe external asset, same-origin cookie fetch, no eval.
(function () {
  "use strict";

  function q(root, name) { return (root || document).querySelector('[data-pencil-name="' + name + '"]'); }
  function qa(root, sel) { return Array.prototype.slice.call((root || document).querySelectorAll(sel)); }
  function qp(root, prefix) { return (root || document).querySelector('[data-pencil-name^="' + prefix + '"]'); }
  function setP(root, prefix, t) { var n = qp(root, prefix); if (n != null && t != null) n.textContent = t; }
  function setT(root, name, t) { var n = q(root, name); if (n != null && t != null) n.textContent = t; }
  function hide(el) { if (el) el.style.display = "none"; }
  function dim(el, title) { if (el) { el.style.opacity = "0.45"; el.style.pointerEvents = "none"; if (title) el.title = title; } }
  function hms(sec) {
    if (sec == null || isNaN(sec)) return "—";
    sec = Math.max(0, Math.round(sec));
    var h = Math.floor(sec / 3600), m = Math.floor((sec % 3600) / 60), s = sec % 60;
    return h + ":" + (m < 10 ? "0" : "") + m + ":" + (s < 10 ? "0" : "") + s;
  }
  var MONTHS_RU = ["января", "февраля", "марта", "апреля", "мая", "июня", "июля", "августа", "сентября", "октября", "ноября", "декабря"];
  function dateRu(iso) {
    if (!iso) return "—";
    var d = new Date(iso);
    return d.getDate() + " " + MONTHS_RU[d.getMonth()];
  }

  var HEADERS = { Accept: "application/json", "Accept-Language": "ru" };
  function apiGet(p) {
    return fetch(p, { headers: HEADERS, credentials: "same-origin" })
      .then(function (r) { return r.ok ? r.json() : Promise.reject(r.status); });
  }

  var T = {};
  var state = { login: null, data: null, selected: 0, streamIdx: 0 };

  function capture() {
    var card = document.querySelector('[data-pencil-name^="MCard "]');
    if (!card) return false;
    T.card = card.cloneNode(true);
    T.cardParent = card.parentNode;
    return true;
  }

  // ---- render ----
  function render() {
    var d = state.data;
    var stream = d.stream;
    if (!stream) { renderEmpty("У канала пока нет завершённых эфиров с чатом."); return; }
    setT(document, "Sel T", "Стрим: " + dateRu(stream.started_at) + (stream.game_name ? " · " + stream.game_name : ""));

    var moments = d.moments || [];
    var clips = (d.clips && d.clips.items) || [];
    setT(document, "Mom Count", moments.length + " найдено");

    qa(T.cardParent, '[data-pencil-name^="MCard "]').forEach(function (n) { n.remove(); });
    qa(T.cardParent, '[data-pencil-name="EmptyNote"]').forEach(function (n) { n.remove(); });
    if (!moments.length) {
      var note = document.createElement("div");
      note.setAttribute("data-pencil-name", "EmptyNote");
      note.style.cssText = "padding:24px 8px;color:#5E5E6B;font-family:Inter,system-ui,sans-serif;font-size:13px;";
      note.textContent = "Пиков чата в этом эфире не найдено — попробуйте другой стрим.";
      T.cardParent.appendChild(note);
      clearPlayer();
      return;
    }

    moments.forEach(function (m, i) {
      var clip = matchedClip(m, clips);
      var card = T.card.cloneNode(true);
      card.setAttribute("data-pencil-name", "MCard " + hms(m.offset_sec));
      setP(card, "MTC T", hms(m.offset_sec));
      setP(card, "MTitle", clip ? clip.title : "Пик чата ×" + (m.multiplier || "—"));
      setP(card, "MRch T", "Пик чата");
      var chip = qp(card, "MRch");
      if (chip) { chip.style.backgroundColor = "#102337"; var ct = qp(chip, "MRch T"); if (ct) ct.style.color = "#4FA9FF"; }
      setP(card, "MDur", clip && clip.duration ? "0:" + String(Math.round(clip.duration)).padStart(2, "0") : Math.round((m.duration_sec || 60) / 60) + " мин");
      card.style.cursor = "pointer";
      paintSelected(card, i === state.selected);
      card.addEventListener("click", function () {
        state.selected = i;
        qa(T.cardParent, '[data-pencil-name^="MCard "]').forEach(function (n, j) { paintSelected(n, j === state.selected); });
        renderPlayer();
      });
      T.cardParent.appendChild(card);
    });
    renderPlayer();
  }

  function paintSelected(card, on) {
    card.style.backgroundColor = on ? "#1E1838" : "#141419";
    card.style.borderColor = on ? "#7B5CFA" : "#25252F";
  }

  function matchedClip(m, clips) {
    return clips.find(function (c) { return c.moment_offset_sec === m.offset_sec; }) || null;
  }

  function renderPlayer() {
    var d = state.data;
    var m = (d.moments || [])[state.selected];
    if (!m) { clearPlayer(); return; }
    var clip = matchedClip(m, (d.clips && d.clips.items) || []);
    setT(document, "Clip Title", clip ? clip.title : "Пик чата ×" + (m.multiplier || "—"));
    setT(document, "TC T", hms(m.offset_sec));
    setT(document, "Reason T", "Пик чата ×" + (m.multiplier || "—"));
    setT(document, "Prev Cap", hms(m.offset_sec) + " — момент выбран");
    if (d.stream && d.stream.duration_sec) setT(document, "VOD T", "VOD · " + hms(d.stream.duration_sec));
    setT(document, "Dur T", clip && clip.duration ? "0:" + String(Math.round(clip.duration)).padStart(2, "0") : Math.round((m.duration_sec || 60) / 60) + " мин");

    var watch = q(document, "Btn Watch");
    if (watch) {
      if (clip && clip.url) {
        watch.style.opacity = "1"; watch.style.pointerEvents = "auto"; watch.style.cursor = "pointer";
        watch.onclick = function () { window.open(clip.url, "_blank", "noopener"); };
        watch.title = "";
      } else {
        dim(watch, d.clips && d.clips.status === "pending" ? "Ищем клип этого момента…" : "Клип этого момента не найден");
      }
    }
  }

  function clearPlayer() {
    ["Clip Title", "TC T", "Reason T", "Prev Cap"].forEach(function (n) { setT(document, n, "—"); });
    dim(q(document, "Btn Watch"), "Нет момента");
  }

  function renderEmpty(msg) {
    setT(document, "Sub", msg);
    setT(document, "Mom Count", "0 найдено");
    qa(T.cardParent, '[data-pencil-name^="MCard "]').forEach(function (n) { n.remove(); });
    clearPlayer();
  }

  // ---- stream selector: click cycles through the last finished streams ----
  function wireSelector() {
    var sel = q(document, "Stream Sel");
    if (!sel) return;
    sel.style.cursor = "pointer";
    sel.title = "Следующий эфир";
    sel.addEventListener("click", function () {
      var streams = (state.data && state.data.streams) || [];
      if (streams.length < 2) return;
      state.streamIdx = (state.streamIdx + 1) % streams.length;
      load(streams[state.streamIdx].id);
    });
  }

  function deferUnbacked() {
    ["FC Клатчи", "FC Смешное", "FC Донаты", "FC Хайлайты"].forEach(function (n) { dim(q(document, n), "Скоро"); });
    dim(q(document, "Btn Shorts"), "Скоро");
    dim(q(document, "Btn Share"), "Скоро");
    hide(q(document, "Transcript")); // needs a per-clip Whisper transcript — follow-up wiring
  }

  // ---- load ----
  var pollTimer;
  function load(streamId) {
    var u = new URLSearchParams({ login: state.login });
    if (streamId) u.set("stream_id", streamId);
    apiGet("/api/v1/me/moments?" + u.toString())
      .then(function (resp) {
        state.data = (resp && resp.data) || {};
        state.selected = 0;
        render();
        // clips are worker-cached: on pending, refetch once shortly after
        clearTimeout(pollTimer);
        if (state.data.clips && state.data.clips.status === "pending") {
          pollTimer = setTimeout(function () { load(streamId); }, 5000);
        }
      })
      .catch(function (status) {
        renderEmpty(status === 404 ? "Канал не найден." : "Не удалось загрузить моменты.");
      });
  }

  function resolveChannel() {
    var fromUrl = new URLSearchParams(location.search).get("login");
    if (fromUrl) { state.login = fromUrl; load(); return; }
    apiGet("/api/v1/user/me")
      .then(function (resp) {
        var u = (resp && resp.data) || {};
        if (u.twitch_login) { state.login = u.twitch_login; load(); return Promise.reject("done"); }
        return apiGet("/api/v1/me/home/recent_channels");
      })
      .then(function (resp) {
        var first = resp && resp.data && resp.data[0];
        if (first) { state.login = first.login; load(); }
        else renderEmpty("Откройте канал через поиск — моменты появятся здесь.");
      })
      .catch(function (e) { if (e !== "done") renderEmpty("Откройте канал через поиск — моменты появятся здесь."); });
  }

  function boot() {
    if (!capture()) return;
    deferUnbacked();
    wireSelector();
    resolveChannel();
  }

  fetch("/api/v1/lk/status", { headers: { Accept: "application/json" }, credentials: "same-origin" })
    .then(function (r) { return r.ok ? r.json() : {}; })
    .then(function (s) {
      if (!s || !s.authenticated) { window.location.href = "/login"; return; }
      boot();
    })
    .catch(function () { window.location.href = "/login"; });
})();
