// Viewer best-moments (screen 07) — wires REAL chat-peak moments + window clips into the faithful
// Pencil export. Auth-gated: /api/v1/lk/status → /login. Data: GET /api/v1/me/moments?login=X
// (chat peaks from the CH per-minute MV; clips from the Helix worker-cache, matched by vod_offset).
// Channel: ?login= param → else the user's own twitch_login → else their first recent channel.
//
// Honest deferrals (backend SCOPING 2026-07-21): AI categories (Клатчи/Смешное/Хайлайты) and
// «Донаты» have no engine/source → those filter chips are dimmed; Shorts/Share export deferred.
// Per-moment transcript is wired to the real Whisper flow: POST /api/v1/clip_transcripts/request
// {clip_id} → poll GET /api/v1/clip_transcripts/:clip_id → segments; 402 = honest free-limit note.
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
    // VOD chip only when the real duration is known — the design's «VOD · 2:14:30» must not survive
    var vodTag = q(document, "VOD Tag");
    if (d.stream && d.stream.duration_sec) {
      if (vodTag) vodTag.style.display = "";
      setT(document, "VOD T", "VOD · " + hms(d.stream.duration_sec));
    } else {
      hide(vodTag);
    }
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
    renderTranscriptState();
  }

  function clearPlayer() {
    ["Clip Title", "TC T", "Reason T", "Prev Cap"].forEach(function (n) { setT(document, n, "—"); });
    setT(document, "Dur T", "—");
    hide(q(document, "VOD Tag")); // the design's «VOD · 2:14:30» must not survive an empty state
    dim(q(document, "Btn Watch"), "Нет момента");
    if (tr.parent) {
      clearTimeout(tr.pollTimer);
      trBtnEnabled(false);
      trNote("Нет момента — расшифровка недоступна.");
    }
  }

  function renderEmpty(msg) {
    setT(document, "Sub", msg);
    setT(document, "Sel T", "Стрим: —"); // the design's «Стрим: 23 июня · Dota 2» must not survive
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

  // ---- transcript (per-clip Whisper: request → poll → segment lines) ----
  var tr = { parent: null, tpl: null, btn: null, pollTimer: null };

  function captureTranscript() {
    var lines = q(document, "Tr Lines");
    if (!lines) return;
    tr.parent = lines;
    var first = lines.querySelector('[data-pencil-name^="TL "]');
    tr.tpl = first ? first.cloneNode(true) : null;
    clearTrLines();
    // clip playback can't seek → don't promise «клик по строке — переход к моменту»
    setT(document, "Tr Note", "");
    // the design has no request affordance — inject the action button into the section header
    var head = q(document, "Tr Head");
    if (head) {
      var btn = document.createElement("div");
      btn.setAttribute("data-pencil-name", "Tr Request Btn");
      btn.textContent = "Расшифровать";
      btn.style.cssText = "padding:6px 14px;border-radius:10px;background:#7B5CFA;color:#FFFFFF;" +
        "font-family:Inter,system-ui,sans-serif;font-size:12px;font-weight:600;cursor:pointer;flex:none;";
      btn.addEventListener("click", requestTranscript);
      head.appendChild(btn);
      tr.btn = btn;
    }
  }

  function clearTrLines() {
    if (!tr.parent) return;
    qa(tr.parent, '[data-pencil-name^="TL "]').forEach(function (n) { n.remove(); });
    qa(tr.parent, '[data-pencil-name="TrNote"]').forEach(function (n) { n.remove(); });
  }

  function trNote(msg) {
    if (!tr.parent) return;
    clearTrLines();
    var d = document.createElement("div");
    d.setAttribute("data-pencil-name", "TrNote");
    d.style.cssText = "padding:10px 4px;color:#5E5E6B;font-family:Inter,system-ui,sans-serif;font-size:13px;";
    d.textContent = msg;
    tr.parent.appendChild(d);
  }

  function trBtnEnabled(on) {
    if (!tr.btn) return;
    tr.btn.style.opacity = on ? "1" : "0.45";
    tr.btn.style.pointerEvents = on ? "auto" : "none";
  }

  function selectedClip() {
    var d = state.data || {};
    var m = (d.moments || [])[state.selected];
    return m ? matchedClip(m, (d.clips && d.clips.items) || []) : null;
  }

  // Called on every moment (re)selection: probe the universal transcript cache, else offer the button.
  function renderTranscriptState() {
    if (!tr.parent) return;
    clearTimeout(tr.pollTimer);
    var clip = selectedClip();
    if (!clip || !clip.id) {
      trBtnEnabled(false);
      trNote("Для этого момента нет клипа — расшифровка недоступна.");
      return;
    }
    trBtnEnabled(true);
    apiGet("/api/v1/clip_transcripts/" + encodeURIComponent(clip.id))
      .then(function (d) { applyTranscript(d, clip.id); })
      .catch(function () { trNote("Нажмите «Расшифровать», чтобы получить текст клипа этого момента."); });
  }

  function applyTranscript(d, clipId) {
    var current = selectedClip();
    if (!current || current.id !== clipId) return; // user switched moments mid-flight
    if (d && d.status === "done" && d.transcript) { trBtnEnabled(false); renderTrLines(d.transcript); return; }
    if (d && (d.status === "queued" || d.status === "processing")) {
      trBtnEnabled(false);
      trNote("Расшифровываем — обычно 2-3 минуты…");
      tr.pollTimer = setTimeout(function () {
        apiGet("/api/v1/clip_transcripts/" + encodeURIComponent(clipId))
          .then(function (nd) { applyTranscript(nd, clipId); })
          .catch(function () { trBtnEnabled(true); trNote("Не удалось получить расшифровку — попробуйте позже."); });
      }, 8000);
      return;
    }
    if (d && d.status === "error") {
      trBtnEnabled(true);
      trNote("Не удалось расшифровать клип — попробуйте ещё раз.");
      return;
    }
    trBtnEnabled(true);
    trNote("Нажмите «Расшифровать», чтобы получить текст клипа этого момента.");
  }

  function renderTrLines(t) {
    clearTrLines();
    var segs = (t && t.segments) || [];
    if (!segs.length && t && t.text) segs = [{ start_sec: 0, text: t.text }];
    if (!segs.length) { trNote("Расшифровка пуста — в клипе не распознана речь."); return; }
    segs.slice(0, 60).forEach(function (s) {
      var ts = hms(s.start_sec);
      var row;
      if (tr.tpl) {
        row = tr.tpl.cloneNode(true);
        row.setAttribute("data-pencil-name", "TL " + ts);
        row.style.backgroundColor = "transparent"; // drop the design's highlighted sample row
        var tEl = row.querySelector('[data-pencil-name^="TL Time "]');
        if (tEl) { tEl.textContent = ts; tEl.setAttribute("data-pencil-name", "TL Time " + ts); }
        var xEl = row.querySelector('[data-pencil-name^="TL Txt "]');
        if (xEl) { xEl.textContent = s.text || ""; xEl.setAttribute("data-pencil-name", "TL Txt " + ts); }
      } else {
        row = document.createElement("div");
        row.setAttribute("data-pencil-name", "TL " + ts);
        row.style.cssText = "padding:8px 10px;color:#9A9AA9;font-family:Inter,system-ui,sans-serif;font-size:14px;";
        row.textContent = ts + "  " + (s.text || "");
      }
      tr.parent.appendChild(row);
    });
  }

  function requestTranscript() {
    var clip = selectedClip();
    if (!clip || !clip.id) return;
    trBtnEnabled(false);
    trNote("Отправляем запрос…");
    fetch("/api/v1/clip_transcripts/request", {
      method: "POST",
      headers: { Accept: "application/json", "Content-Type": "application/json", "Accept-Language": "ru" },
      credentials: "same-origin",
      body: JSON.stringify({ clip_id: clip.id }),
    })
      .then(function (r) { return r.json().then(function (b) { return { status: r.status, ok: r.ok, body: b }; }); })
      .then(function (res) {
        if (res.status === 402) {
          // free tier: 10 transcripts / calendar month — honest limit message from the API
          trNote((res.body && res.body.message) || "Лимит бесплатных расшифровок в этом месяце исчерпан.");
          return;
        }
        if (!res.ok && res.status !== 202) {
          trBtnEnabled(true);
          trNote((res.body && res.body.message) || "Не удалось запросить расшифровку.");
          return;
        }
        applyTranscript(res.body, clip.id);
      })
      .catch(function () { trBtnEnabled(true); trNote("Не удалось запросить расшифровку — попробуйте позже."); });
  }

  function deferUnbacked() {
    ["FC Клатчи", "FC Смешное", "FC Донаты", "FC Хайлайты"].forEach(function (n) { dim(q(document, n), "Скоро"); });
    dim(q(document, "Btn Shorts"), "Скоро");
    dim(q(document, "Btn Share"), "Скоро");
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
    captureTranscript();
    wireSelector();
    resolveChannel();
  }

  // Auth gate: ONLY the lk/status probe (and its own network failure) decides the /login redirect.
  // Data/boot errors render honest empty/error states instead of bouncing the user to /login.
  fetch("/api/v1/lk/status", { headers: { Accept: "application/json" }, credentials: "same-origin" })
    .then(function (r) { return r.ok ? r.json() : {}; })
    .then(
      function (s) {
        if (!s || !s.authenticated) { window.location.href = "/login"; return; }
        try { boot(); } catch (e) { if (T.cardParent) renderEmpty("Не удалось загрузить моменты."); }
      },
      function () { window.location.href = "/login"; }
    );
})();
