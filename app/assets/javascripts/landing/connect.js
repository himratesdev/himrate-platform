// Streamer connect onboarding (screen 11) — wires REAL connection state into the faithful export.
// Auth-gated: /api/v1/lk/status → /login. Data: GET /api/v1/me/connect/status (oauth link + granted
// scopes, observation state, real collection stats). Card A action = enabling observation of the
// user's OWN channel (POST /api/v1/channels/:id/track — free for the owner, ChannelPolicy
// streamer_on_channel?). No mod-bot / autoposting engines exist → the Autoposting section is
// honestly dimmed «Скоро» (same pattern as settings.js deferTelegramCard). CSP-safe, no eval.
(function () {
  "use strict";

  var GREEN = "#25D9A4", GRAY = "#5E5E6B", RED = "#FB4E55";

  function q(root, name) { return (root || document).querySelector('[data-pencil-name="' + name + '"]'); }
  function setT(root, name, t) { var n = q(root, name); if (n != null && t != null) n.textContent = t; }
  function hide(el) { if (el) el.style.display = "none"; }

  var HEADERS = { Accept: "application/json", "Accept-Language": "ru" };
  function apiGet(p) {
    return fetch(p, { headers: HEADERS, credentials: "same-origin" })
      .then(function (r) {
        if (!r.ok) return Promise.reject(r.status);
        // guard: a 200 with a non-JSON body (proxy error page) must reject, not throw through the chain
        return r.json().catch(function () { return Promise.reject("bad_json"); });
      });
  }

  function card(title) {
    var t = document.querySelectorAll('[data-pencil-name="Title"]');
    for (var i = 0; i < t.length; i++) {
      if (t[i].textContent.trim() === title) return t[i].closest('[data-pencil-name^="Card"]');
    }
    return null;
  }

  function setStatus(cardEl, text, color) {
    if (!cardEl) return;
    setT(cardEl, "Status T", text);
    var st = q(cardEl, "Status T"); if (st) st.style.color = color;
    var dot = q(cardEl, "Status Dot"); if (dot) dot.style.backgroundColor = color;
  }

  function minutesAgo(iso) {
    if (!iso) return null;
    var m = Math.round((Date.now() - new Date(iso).getTime()) / 60000);
    if (m < 1) return "только что";
    if (m < 60) return m + " мин";
    if (m < 1440) return Math.round(m / 60) + " ч";
    return Math.round(m / 1440) + " дн";
  }

  // ---- non-linked state (honest CTA — the page is about the user's own channel) ----
  function renderConnectState() {
    ["Connection Cards", "Data Status", "Autoposting", "Free Note", "Channel Pill"]
      .forEach(function (n) { hide(q(document, n)); });
    var content = q(document, "Content") || document.body;
    var box = document.createElement("div");
    box.setAttribute("data-pencil-name", "ConnectState");
    box.style.cssText = "width:100%;padding:64px 24px;text-align:center;color:#C7C7D1;font-family:Inter,system-ui,sans-serif;";
    box.innerHTML =
      '<div style="font-size:18px;font-weight:700;margin-bottom:8px;">Привяжите Twitch, чтобы подключить канал</div>' +
      '<div style="font-size:14px;color:#9A9AA9;max-width:480px;margin:0 auto 20px;">HimRate определит ваш канал по Twitch-аккаунту, после чего можно включить наблюдение и следить за сбором данных.</div>' +
      '<a href="/auth/web/twitch" style="display:inline-block;background:#7B5CFA;color:#fff;text-decoration:none;padding:11px 20px;border-radius:12px;font-weight:600;font-size:14px;">Войти через Twitch</a>';
    content.appendChild(box);
  }

  // ---- Card A «Наблюдение канала» — real track state + action ----
  function renderObservation(cardA, data) {
    var obs = data.observation || {};
    var stats = data.stats || {};
    var btn = q(cardA, "Observe Btn");

    if (obs.tracked) {
      setStatus(cardA, "Подключено", GREEN);
      if (btn) {
        setT(btn, "Observe T", "Наблюдение включено");
        btn.style.backgroundColor = "#1E1E28";
        btn.style.cursor = "default";
      }
    } else if (!obs.channel_id) {
      // Twitch linked but the channel isn't in our registry yet — honest state, no fake button.
      setStatus(cardA, "Канал ещё не в базе", GRAY);
      if (btn) {
        setT(btn, "Observe T", "Канал появится после первого стрима");
        btn.style.backgroundColor = "#1E1E28";
        btn.style.cursor = "default";
      }
    } else {
      setStatus(cardA, "Не подключено", GRAY);
      if (btn) {
        btn.style.cursor = "pointer";
        btn.addEventListener("click", function () {
          setT(btn, "Observe T", "Включаем…");
          fetch("/api/v1/channels/" + obs.channel_id + "/track", {
            method: "POST", headers: HEADERS, credentials: "same-origin"
          }).then(function (r) {
            if (r.ok || r.status === 409) { window.location.reload(); return; }
            return r.json().then(function (b) { return Promise.reject((b && b.message) || r.status); });
          }).catch(function (e) {
            setT(btn, "Observe T", "Не удалось включить: " + e);
            btn.style.backgroundColor = RED;
          });
        });
      }
    }
    var sync = minutesAgo(stats.last_sync_at);
    setT(cardA, "Foot T A", sync
      ? (obs.is_monitored ? "Активен · последняя синхронизация " + sync + " назад" : "Последняя синхронизация " + sync + " назад")
      : "Данных пока нет — они появятся после первого стрима под наблюдением");
  }

  // ---- Card B «Broadcaster OAuth» — real link + granted scopes ----
  function renderOauth(cardB, oauth) {
    if (oauth.linked) {
      setStatus(cardB, "Подключено", GREEN);
      var scopes = (oauth.scopes || []).length ? oauth.scopes.join(", ") : "базовый профиль";
      setT(cardB, "Perm T", "Выданные права: " + scopes + ". Доступ можно отозвать в любой момент.");
      var btn = q(cardB, "Connect Btn");
      if (btn) {
        setT(btn, "Connect T", "Переподключить Twitch");
        btn.style.cursor = "pointer";
        btn.addEventListener("click", function () { window.location.href = "/auth/web/twitch"; });
      }
    } else {
      setStatus(cardB, "Не подключено", GRAY);
      var b = q(cardB, "Connect Btn");
      if (b) {
        b.style.cursor = "pointer";
        b.addEventListener("click", function () { window.location.href = "/auth/web/twitch"; });
      }
    }
  }

  // ---- Data Status tiles — real collection stats ----
  function renderStats(stats) {
    stats = stats || {};
    setT(document, "Tile Val Стримов собрано", stats.streams_collected != null ? String(stats.streams_collected) : "—");
    setT(document, "Tile Val Часов эфира", stats.hours_live != null ? stats.hours_live + " ч" : "—");
    setT(document, "Tile Val Источника данных", stats.sources_active != null ? stats.sources_active + " из 3" : "—");
    var sync = minutesAgo(stats.last_sync_at);
    setT(document, "Tile Val Последняя синхронизация", sync || "—");

    var live = (stats.sources_active || 0) > 0;
    setT(document, "Live T", live ? "В реальном времени" : "Нет активного сбора");
    var dot = q(document, "Live Dot"); if (dot) dot.style.backgroundColor = live ? GREEN : GRAY;
  }

  // ---- Autoposting — engine doesn't exist → honest «Скоро» (settings.js pattern) ----
  function deferAutoposting() {
    var ap = q(document, "Autoposting");
    if (!ap) return;
    setT(ap, "AP Sub", "Скоро — автопостинг событий стрима в разработке");
    ["Triggers"].forEach(function (n) {
      var el = q(ap, n);
      if (el) { el.style.opacity = "0.4"; el.style.pointerEvents = "none"; el.title = "Скоро"; }
    });
  }

  // ---- data-load failure — honest error state instead of the design's sample statuses ----
  function renderLoadError() {
    ["Connection Cards", "Data Status", "Autoposting", "Free Note", "Channel Pill"]
      .forEach(function (n) { hide(q(document, n)); });
    var content = q(document, "Content") || document.body;
    var box = document.createElement("div");
    box.setAttribute("data-pencil-name", "LoadError");
    box.style.cssText = "width:100%;padding:64px 24px;text-align:center;color:#C7C7D1;font-family:Inter,system-ui,sans-serif;font-size:14px;";
    box.textContent = "Не удалось загрузить состояние подключения — обновите страницу.";
    content.appendChild(box);
  }

  // Auth gate: ONLY the lk/status probe (and its own network failure — incl. a 502/HTML body the
  // JSON guard rejects) decides the /login redirect. A failed connect-status load renders the honest
  // error state instead of bouncing an authenticated user to /login.
  apiGet("/api/v1/lk/status").then(
    function (s) {
      if (!s || !s.authenticated) { window.location.href = "/login"; return; }
      deferAutoposting();
      apiGet("/api/v1/me/connect/status")
        .then(function (resp) {
          var data = (resp && resp.data) || {};
          if (!data.oauth || !data.oauth.linked) { renderConnectState(); return; }
          setT(document, "Channel T", "twitch.tv/" + (data.oauth.login || ""));
          renderObservation(card("Наблюдение канала"), data);
          renderOauth(card("Broadcaster OAuth"), data.oauth);
          renderStats(data.stats);
        })
        .catch(renderLoadError);
    },
    function () { window.location.href = "/login"; }
  );
})();
