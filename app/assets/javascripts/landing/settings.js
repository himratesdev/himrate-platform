// Viewer settings (screen 06) — wires REAL privacy toggles + connected accounts into the faithful
// Pencil export. Auth-gated: /api/v1/lk/status (httpOnly cookie) → /login when unauthenticated.
//
// Honest-data rules applied:
// - Privacy card: the design's 5 sample toggles are product-level prefs with NO backend; the REAL
//   privacy backend is M15 «Видимость моей активности» (GET/PUT /api/v1/me/privacy, TASK-113) — so
//   we render the REAL 5 toggles with their canonical wireframe labels (internal M-codes dropped per
//   the first-time-user clarity rule), wired to real writes. No fabricated prefs.
// - Sync card: Twitch + Google connection state is real (GET /api/v1/user/me: twitch_linked/
//   google_linked); a Google row is cloned from the Twitch template (the design predates Google
//   login). Telegram/Steam have no backend → «не подключён» + disabled. Sync-frequency → deferred.
// - Telegram-bot card: no bot exists → whole card dimmed «Скоро». Nothing faked.
// CSP-safe external asset, same-origin cookie fetch, no eval.
(function () {
  "use strict";

  var ON_BG = "#7B5CFA", OFF_BG = "#25252F";

  // Canonical M15 toggles (TASK-113 wireframe verbatim; M-codes dropped — user-facing clarity rule).
  var TOGGLES = [
    { key: "display_name_visible", label: "Показывать display-name", desc: "Стример увидит ваш реальный ник" },
    { key: "recognition", label: "Recognition · статус зрителя", desc: "Показывать стримеру ваш статус зрителя" },
    { key: "chat_capture", label: "Захват чата", desc: "Локально, шифруется" },
    { key: "device_telemetry", label: "Device-телеметрия", desc: "Desktop / Mobile / TV разрез" },
    { key: "aggregated_stats", label: "Анонимная агрегированная статистика", desc: "Для сопоставления с похожими зрителями" },
  ];
  // The design's 5 sample privacy rows (no backend) — replaced by the real ones above.
  var DESIGN_PRIVACY_ROWS = [
    "Row · Публичный профиль", "Row · Делиться историей просмотра",
    "Row · Участвовать в «Похожих зрителях»", "Row · Активность в реальном времени",
    "Row · Персональные AI-инсайты",
  ];

  function q(root, name) { return (root || document).querySelector('[data-pencil-name="' + name + '"]'); }
  function qp(root, prefix) { return (root || document).querySelector('[data-pencil-name^="' + prefix + '"]'); }
  function setP(root, prefix, t) { var n = qp(root, prefix); if (n != null && t != null) n.textContent = t; }
  function dim(el, title) { if (el) { el.style.opacity = "0.45"; el.style.pointerEvents = "none"; if (title) el.title = title; } }

  var HEADERS = { Accept: "application/json", "Content-Type": "application/json", "Accept-Language": "ru" };
  function apiGet(p) { return fetch(p, { headers: HEADERS, credentials: "same-origin" }).then(function (r) { return r.ok ? r.json() : Promise.reject(r.status); }); }
  function apiPut(p, body) {
    return fetch(p, { method: "PUT", headers: HEADERS, credentials: "same-origin", body: JSON.stringify(body) })
      .then(function (r) { return r.ok ? r.json() : Promise.reject(r.status); });
  }

  // ---- saved chip feedback ----
  var savedChip, savedTimer;
  function flashSaved() {
    if (!savedChip) return;
    savedChip.style.visibility = "visible";
    clearTimeout(savedTimer);
    savedTimer = setTimeout(function () { savedChip.style.visibility = "hidden"; }, 2000);
  }

  // ---- privacy card (real M15 toggles) ----
  var toggleTemplate, privacyBody;
  var toggleState = {};

  function paintSwitch(row, on) {
    var sw = qp(row, "Row Sw"); var knob = qp(row, "Row Knob");
    if (sw) sw.style.backgroundColor = on ? ON_BG : OFF_BG;
    if (knob) knob.style.left = on ? "18px" : "2px";
  }

  function buildToggleRow(t) {
    var row = toggleTemplate.cloneNode(true);
    row.setAttribute("data-pencil-name", "Row · " + t.key);
    setP(row, "Row Label", t.label);
    setP(row, "Row Desc", t.desc);
    paintSwitch(row, !!toggleState[t.key]);
    var sw = qp(row, "Row Sw");
    if (sw) {
      sw.style.cursor = "pointer";
      sw.addEventListener("click", function () {
        var next = !toggleState[t.key];
        var body = { toggles: {} };
        body.toggles[t.key] = next;
        apiPut("/api/v1/me/privacy", body)
          .then(function (resp) {
            var toggles = resp && resp.data && resp.data.toggles;
            if (toggles) toggleState = toggles;
            else toggleState[t.key] = next;
            paintSwitch(row, !!toggleState[t.key]);
            paintPrivacyCap();
            flashSaved();
          })
          .catch(function () { paintSwitch(row, !!toggleState[t.key]); });
      });
    }
    return row;
  }

  function paintPrivacyCap() {
    var onCount = TOGGLES.filter(function (t) { return toggleState[t.key]; }).length;
    setP(document, "Card Cap T · Приватность", onCount === TOGGLES.length ? "Всё включено" : onCount + " из " + TOGGLES.length);
  }

  function renderPrivacy() {
    var firstRow = q(document, DESIGN_PRIVACY_ROWS[0]);
    privacyBody = q(document, "Card Body · Приватность");
    if (!firstRow || !privacyBody) return;
    toggleTemplate = firstRow.cloneNode(true);

    apiGet("/api/v1/me/privacy")
      .then(function (resp) {
        toggleState = (resp && resp.data && resp.data.toggles) || {};
        DESIGN_PRIVACY_ROWS.forEach(function (name) { var n = q(privacyBody, name); if (n) n.remove(); });
        TOGGLES.forEach(function (t) { privacyBody.appendChild(buildToggleRow(t)); });
        paintPrivacyCap();
        // clarify what this card actually governs (M15 activity-visibility, not generic profile prefs)
        setP(document, "Card Title · Приватность", "Видимость моей активности");
      })
      .catch(function () {
        dim(q(document, "Card · Приватность"), "Недоступно");
      });
  }

  // ---- sync card (connected accounts) ----
  function renderAccounts() {
    apiGet("/api/v1/user/me")
      .then(function (resp) {
        var u = (resp && resp.data) || {};
        // Twitch — real state
        var tw = q(document, "Acc · Twitch");
        if (tw) {
          if (u.twitch_linked) {
            setP(tw, "Acc Hd", u.twitch_login || u.username || "подключён");
          } else {
            setP(tw, "Acc Hd", "не подключён");
            setP(tw, "Acc St T", "Не подключён");
            var d = qp(tw, "Acc St Dot"); if (d) d.style.backgroundColor = "#5E5E6B";
          }
        }
        // Google — real state; the design predates Google login → clone the Twitch row as template.
        if (tw && !q(document, "Acc · Google")) {
          var g = tw.cloneNode(true);
          g.setAttribute("data-pencil-name", "Acc · Google");
          setP(g, "Acc Nm", "Google");
          setP(g, "Acc Hd", u.google_linked ? (u.email || "подключён") : "не подключён");
          setP(g, "Acc St T", u.google_linked ? "Подключён" : "Не подключён");
          var gd = qp(g, "Acc St Dot"); if (gd) gd.style.backgroundColor = u.google_linked ? "#25D9A4" : "#5E5E6B";
          tw.parentNode.insertBefore(g, tw.nextSibling);
        }
      })
      .catch(function () {});

    // Telegram / Steam — no backend → honest not-connected + disabled.
    var tg = q(document, "Acc · Telegram");
    if (tg) { setP(tg, "Acc Hd", "не подключён"); setP(tg, "Acc St T", "Скоро"); var td = qp(tg, "Acc St Dot"); if (td) td.style.backgroundColor = "#5E5E6B"; }
    dim(q(document, "Acc Btn · Steam"), "Скоро");
    // Sync frequency — no backend → deferred.
    dim(q(document, "Freq Wrap") || q(document, "Freq Seg"), "Скоро");
  }

  // ---- telegram-bot card — no bot backend → dimmed, honestly labelled ----
  function deferTelegramCard() {
    var card = q(document, "Card · Telegram-бот");
    if (!card) return;
    setP(document, "Card Cap T · Telegram-бот", "Скоро");
    var capDot = q(document, "Card Cap Dot · Telegram-бот"); if (capDot) capDot.style.backgroundColor = "#5E5E6B";
    var body = q(document, "Card Body · Telegram-бот");
    dim(body, "Скоро — Telegram-бот в разработке");
    // Blank the design's sample personal data — even dimmed, a fake handle/date reads as real.
    setP(document, "TG Handle", "—");
    setP(document, "TG Linked", "аккаунт не привязан");
    setP(document, "TG Av", "?");
  }

  // ---- boot ----
  function boot() {
    savedChip = q(document, "Saved Chip");
    if (savedChip) savedChip.style.visibility = "hidden"; // only after a real successful write
    renderPrivacy();
    renderAccounts();
    deferTelegramCard();
  }

  fetch("/api/v1/lk/status", { headers: { Accept: "application/json" }, credentials: "same-origin" })
    .then(function (r) { return r.ok ? r.json() : {}; })
    .then(function (s) {
      if (!s || !s.authenticated) { window.location.href = "/login"; return; }
      boot();
    })
    .catch(function () { window.location.href = "/login"; });
})();
