// Public channel card (screen 02) — wires REAL data into the faithful Pencil-export markup.
// Fetches the public GET /api/v1/channels/:login/card (no auth) and populates the design's
// data-pencil-name anchors. Layers 1-3 (headline + reputation) are free on any channel per
// access-model v2. CSP-safe: external asset, same-origin fetch (connect_src :self). No eval.
(function () {
  "use strict";

  // /c/:login → login
  var parts = window.location.pathname.split("/").filter(Boolean);
  var login = parts.length ? decodeURIComponent(parts[parts.length - 1]) : null;
  if (!login) return;

  var BAND_RU = {
    impeccable: "Безупречная",
    stable: "Стабильная",
    variable: "Изменчивая",
    unstable: "Нестабильная",
  };
  // Band colour (5 values — PR3b TI v2: green|yellow|red|grey|amber) → the design's hero colour.
  var LABEL_COLOR = {
    green: "#25D9A4",
    yellow: "#F5C451",
    red: "#F0616D",
    grey: "#9A9AA9",
    amber: "#F6A823",
  };

  function el(pencilName) {
    return document.querySelector('[data-pencil-name="' + pencilName + '"]');
  }
  function setText(pencilName, text) {
    var node = el(pencilName);
    if (node != null && text != null) node.textContent = text;
  }
  // RU thousands: 4200 → "4 200" (non-breaking space, matches the design).
  function fmt(n) {
    if (n == null || isNaN(n)) return "—";
    return Math.round(n).toString().replace(/\B(?=(\d{3})+(?!\d))/g, " ");
  }

  function render(card) {
    var data = (card && card.data) || {};
    var channel = data.channel || {};
    var layers = data.layers || {};
    var hl = (layers.headline && layers.headline.data) || {};
    var rep =
      (layers.reputation && layers.reputation.data && layers.reputation.data.current) || {};

    // Header
    setText("H Name", channel.display_name || login);
    setText("H Meta", "twitch.tv/" + (channel.login || login));
    var liveNode = el("H Live T");
    if (liveNode && !hl.is_live) liveNode.style.display = "none";

    // Layer 1 — real vs shown. Dual-contract (PR3b TI v2):
    //   • v2 headline: erv = the engine's subtracted real-viewer COUNT (native), ccv = V (shown),
    //     authenticity = % real, band.color = 5-colour verdict. shown−real = engine's F̂ — no
    //     client-side re-derivation.
    // Wording is legal-safe: neutral "скрытая разница" — never "боты/накрутка" (v3 doctrine).
    var ervPct = hl.authenticity;
    var real = hl.erv;
    var live = !!hl.is_live && hl.ccv != null;
    var shown = hl.ccv != null ? hl.ccv : (real != null && ervPct ? Math.round(real / (ervPct / 100)) : null);
    // Clamp at 0: v2 live shown (current CCV snapshot) can dip below the last-computed real
    // (row up to ~30s stale) — a negative "difference" is a display artifact, not data (CR SF-1).
    var bots = shown != null && real != null ? Math.max(0, shown - real) : null;
    var botPct = ervPct != null ? Math.round(100 - ervPct) : null;
    var realPct = ervPct != null ? Math.round(ervPct) : null;

    // Offline card is last-stream data, not "now" — keep the label honest.
    if (!live) setText("L1 Label", "РЕАЛЬНЫЕ ЗРИТЕЛИ · ПОСЛЕДНИЙ ЭФИР");

    var bandColor = hl.band && hl.band.color;
    setText("L1 Real", fmt(real));
    var realNode = el("L1 Real");
    if (realNode && bandColor && LABEL_COLOR[bandColor]) {
      realNode.style.color = LABEL_COLOR[bandColor];
    }
    setText("L1 Shown", "/ " + fmt(shown) + " показано");
    setText("L1 D1 T", "−" + fmt(bots) + " скрытая разница");
    setText("L1 D2 T", botPct != null ? "−" + botPct + "% от показанных" : "—");
    setText("L1 Total", "Всего показано Twitch: " + fmt(shown));
    setText(
      "Leg T bot",
      "Скрытая разница " + fmt(bots) + " · " + (botPct != null ? botPct + "%" : "—")
    );
    setText("Leg T real", "Реальные " + fmt(real) + " · " + (realPct != null ? realPct + "%" : "—"));

    // Reliability band (reputation) + anomaly label (band label via i18n'd erv_label from API).
    if (rep.band) setText("L1 Rep T", "Надёжность: " + (BAND_RU[rep.band] || rep.band));
    var anomLabel = hl.erv_label || null;
    if (anomLabel) {
      setText("L1 Anom T", anomLabel);
      var anomNode = el("L1 Anom T");
      if (anomNode && bandColor && LABEL_COLOR[bandColor]) {
        anomNode.style.color = LABEL_COLOR[bandColor];
      }
    }

    // Real freshness stamp (the export's «обновлено 8 сек назад» mock is scrubbed server-side).
    if (hl.calculated_at) {
      var age = Math.max(0, Math.round((Date.now() - new Date(hl.calculated_at).getTime()) / 60000));
      setText("Updated", age < 1 ? "обновлено только что" : "обновлено " + age + " мин назад");
    }

    renderChecks(hl);
    renderReputation(layers.reputation && layers.reputation.data);
  }

  // W2: real L2 — check rows driven by the REAL public /trust-headline signals (band verdict +
  // reason_codes). No invented numbers: rows without a real code are hidden.
  var REASON_RU = {
    CHATTER_QUALITY_HIGH: ["Качество чата", "аудитория с историей — признак живых зрителей", "ok"],
    CHATTER_QUALITY_LOW: ["Качество чата", "мало аккаунтов с историей — сигнал внимания", "warn"],
    SELF_HISTORY_STABLE_CLEAN: ["История канала", "текущий эфир совпадает с собственной нормой", "ok"],
    SELF_HISTORY_INFLATION_EVENT: ["История канала", "разовый всплеск против собственной нормы", "warn"],
    SELF_HISTORY_SUSTAINED_INFLATION: ["История канала", "устойчивое превышение собственной нормы", "warn"],
    HARD_NAMED_FRACTION: ["Известные боты", "в чате замечены аккаунты из бот-реестров", "warn"],
    WIDE_INTERVAL_THIN_SAMPLE: ["Достаточность выборки", "оценка с широким интервалом — данных пока мало", "dim"],
    PROVISIONAL_BASIC: ["Глубина истории", "предварительная оценка — меньше 10 стримов", "dim"],
    ONLINE_EXCEEDS_ACTIVITY: ["Онлайн vs активность", "онлайн выше наблюдаемой активности чата", "warn"]
  };
  var STATE_COLOR = { ok: "#25D9A4", warn: "#F6A823", dim: "#9A9AA9" };

  function renderChecks(hl) {
    var band = hl.band || {};
    var rows = [];
    var bandState = band.color === "green" ? "ok" : band.color === "grey" ? "dim" : "warn";
    // No verdict at all (error/empty scrub) → zero rows, everything hidden below.
    if (hl.erv_label || band.color) rows.push(["Вердикт эфира", hl.erv_label || "—", bandState]);
    (hl.reason_codes || []).forEach(function (code) {
      var m = REASON_RU[code];
      if (m) rows.push(m);
    });
    for (var i = 1; i <= 7; i++) {
      var row = el("Chk " + i);
      if (!row) continue;
      if (i <= rows.length) {
        setText("Chk Nm " + i, rows[i - 1][0]);
        setText("Chk Vl " + i, rows[i - 1][1]);
        var ic = el("Chk Ic " + i);
        if (ic) ic.style.background = STATE_COLOR[rows[i - 1][2]] + "22";
        var icPath = document.querySelector('[data-pencil-name="Chk Ic I ' + i + '"] path');
        if (icPath) icPath.setAttribute("fill", STATE_COLOR[rows[i - 1][2]]);
        var pill = el("Chk Pl " + i);
        if (pill) pill.style.display = "none"; // pills carried mock statuses — the value line says it
      } else {
        row.style.display = "none";
      }
    }
    setText("Checks Pass", rows.length ? rows.length + " реальных сигналов" : "—");
  }

  // W2: real L3 — the drawn 4-level reputation scale highlights the channel's ACTUAL band from
  // the public reputation layer; mock trend bars are hidden (no fabricated history).
  var BAND_LEVEL = { impeccable: 1, stable: 2, variable: 3, unstable: 4 };

  function renderReputation(repData) {
    var current = (repData && repData.current) || {};
    var lvl = BAND_LEVEL[current.band];
    var curMark = el("Lv Cur 2");
    if (curMark) curMark.style.display = "none"; // static mock marker off Стабильная
    for (var i = 1; i <= 4; i++) {
      var row = el("Lv " + i);
      if (!row) continue;
      if (lvl) {
        row.style.opacity = i === lvl ? "1" : "0.45";
        if (i === lvl && curMark) {
          curMark.style.display = "";
          row.appendChild(curMark);
        }
      }
    }
    var count = current.stream_count;
    setText("Trend Avg", lvl ? ("окно: " + (count != null ? count : "—") + " стримов") : "недостаточно истории");
    var chart = el("Trend Chart");
    if (chart) chart.style.display = "none"; // sample bars — no fabricated series
  }

  function renderError() {
    setText("H Name", login);
    setText("H Meta", "Канал не найден или ещё не проанализирован");
    // Reset the legend rows too ("Leg T bot"/"Leg T real") — otherwise the error state
    // leaves the static mock ("Скрытая разница 800 · 16%") under the graph on the PUBLIC
    // /c/:login page, attached to a real streamer's name. Happy-path overwrites them
    // (setText above), error-path must clear them.
    ["L1 Real", "L1 Shown", "L1 D1 T", "L1 D2 T", "L1 Total", "Leg T bot", "Leg T real"].forEach(function (p) {
      setText(p, "—");
    });
    // The mock check pills («норма»/«внимание»), the static reputation marker and the sample
    // trend bars are only scrubbed on the happy path (renderChecks/renderReputation) — run the
    // same scrub here so an API failure never shows fabricated verdicts on a real channel.
    renderChecks({});
    renderReputation(null);
  }

  // Static export chrome that must never show as-is:
  //  • «DH» topbar avatar — a signed-in persona shown to guests on a public page;
  //  • «Подтверждён в HimRate» — a verification badge with no verification system behind it.
  (function () {
    var av = el("TB Avatar");
    if (av) av.style.display = "none";
    var verified = el("H Verified T");
    if (verified) {
      var wrap = verified.parentElement || verified;
      wrap.style.display = "none";
    }
  })();

  // Navigation wiring (SITE-AUDIT-2 CJM). The public card renders on the landing layout
  // WITHOUT hr-shared.js (the marketing nav engine), so its chrome was dead: the card was
  // a navigational dead-end (no escape to marketing) AND the registration Gate CTAs did
  // nothing — the biggest SEO→signup conversion leak. Wire them explicitly here.
  function nav(pencilName, dest) {
    var n = el(pencilName);
    if (!n) return;
    n.style.cursor = "pointer";
    n.addEventListener("click", function (e) {
      e.preventDefault();
      if (dest === "back") {
        if (window.history.length > 1) window.history.back();
        else window.location.href = "/";
      } else {
        window.location.href = dest;
      }
    });
  }
  // The card lives on the apex (SEO host) while the LK lives on app.himrate.com — LK links are
  // cross-host there. Off production (staging/localhost run single-host) use the /app scheme.
  var APP_ORIGIN = window.location.hostname === "himrate.com" ? "https://app.himrate.com" : "";
  function appHref(p) { return APP_ORIGIN ? APP_ORIGIN + p : "/app" + p; }

  // W5 deep link: the graph page's ego mode for THIS channel (registered surface — gates to
  // login like the other LK links). Injected as a real anchor under the reputation layer.
  (function () {
    var l3 = el("L3 Reputation");
    if (!l3) return;
    var a = document.createElement("a");
    a.setAttribute("data-pencil-name", "Graph Link");
    a.href = appHref("/graph?focus=" + encodeURIComponent(login));
    a.textContent = "Паутинка пересечений аудитории этого канала →";
    a.style.cssText = "display:block;margin:14px 0 0;color:#A78BFA;font:500 13.5px Inter,system-ui,sans-serif;text-decoration:none;";
    l3.appendChild(a);
  })();

  // Registration Gate CTAs: a signed-in visitor goes straight to the LK surface for this channel
  // (bouncing them через /login costs three hops and loses the channel context); guests → /login.
  fetch("/api/v1/lk/status", { headers: { Accept: "application/json" }, credentials: "same-origin" })
    .then(function (r) { return r.ok ? r.json() : {}; })
    .catch(function () { return {}; })
    .then(function (s) {
      var authed = !!(s && s.authenticated);
      nav("Gate CTA1", authed ? appHref("/streamers/" + encodeURIComponent(login)) : "/login");
      nav("Gate CTA2", authed ? appHref("/streamers/" + encodeURIComponent(login)) : "/login");
      // The export ships the LK sidebar on this page but brand_nav.js isn't loaded here — wire
      // its three live items cross-host so they aren't dead clicks on the busiest SEO surface.
      nav("Nav · Главная", authed ? appHref("/home") : "/login");
      nav("Nav · Куда пойти", authed ? appHref("/discover") : "/login");
      nav("Nav · Watchlists", authed ? appHref("/watchlists") : "/login");
      var acct = el("Account");
      if (acct) nav("Account", authed ? appHref("/home") : "/login");
    });

  // Escape hatches back to marketing (the card is a shared / SEO landing surface).
  nav("Logo", "/");
  nav("Wordmark", "/");
  nav("BC Home", "/");
  nav("BC Back", "back");

  fetch("/api/v1/channels/" + encodeURIComponent(login) + "/card", {
    // This is a RU page (lang="ru") — pin the API locale to ru so labels (erv_label) come back
    // in Russian regardless of the visitor's browser locale.
    headers: { Accept: "application/json", "Accept-Language": "ru" },
    credentials: "same-origin",
  })
    .then(function (r) {
      if (!r.ok) throw new Error("HTTP " + r.status);
      return r.json();
    })
    .then(render)
    .catch(function (e) {
      if (window.console) console.warn("[channel_card] load failed:", e);
      renderError();
    });
})();
