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

  // Honest-data guard (PO caught «Прирост онлайна +1 200 за 35 с» as a leftover sample,
  // 2026-07-20): the deep sections below layer 1 (L2 Drill = 7 checks + CCV/ERV charts + bot-raid,
  // L3 Reputation = trend samples) are STILL static design samples — no wiring yet. Hide them until
  // each is wired to real data (follow-ups); only the real layer-1 block + the registration Gate CTA
  // stay visible. Runs immediately (script loads at end of body).
  ["L2 Drill", "L3 Reputation"].forEach(function (name) {
    var n = document.querySelector('[data-pencil-name="' + name + '"]');
    if (n) n.style.display = "none";
  });

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
    //   • v1 headline (pre-flip): erv_count/erv_percent as before (shown backed out when offline).
    // Wording is legal-safe: neutral "скрытая разница" — never "боты/накрутка" (v3 doctrine).
    var isV2 = hl.engine_version === "v2";
    var ervPct = isV2 ? hl.authenticity : hl.erv_percent;
    var live = !!hl.is_live && hl.ccv != null;
    var shown, real;
    if (isV2) {
      real = hl.erv;
      shown = hl.ccv != null ? hl.ccv : (real != null && ervPct ? Math.round(real / (ervPct / 100)) : null);
    } else if (live) {
      shown = hl.ccv;
      real = ervPct != null ? Math.round(shown * ervPct / 100) : hl.erv_count;
    } else if (hl.erv_count != null && ervPct != null && ervPct > 0) {
      real = hl.erv_count;
      shown = Math.round(real / (ervPct / 100));
    } else {
      real = hl.erv_count;
      shown = hl.ccv; // may be null → "—"
    }
    // Clamp at 0: v2 live shown (current CCV snapshot) can dip below the last-computed real
    // (row up to ~30s stale) — a negative "difference" is a display artifact, not data (CR SF-1).
    var bots = shown != null && real != null ? Math.max(0, shown - real) : null;
    var botPct = ervPct != null ? Math.round(100 - ervPct) : null;
    var realPct = ervPct != null ? Math.round(ervPct) : null;

    // Offline card is last-stream data, not "now" — keep the label honest.
    if (!live) setText("L1 Label", "РЕАЛЬНЫЕ ЗРИТЕЛИ · ПОСЛЕДНИЙ ЭФИР");

    var bandColor = isV2 ? (hl.band && hl.band.color) : hl.erv_label_color;
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

    // Reliability band (reputation) + anomaly label (v2: band label via i18n'd erv_label from API;
    // v1: legacy erv_label). Both already RU + coloured.
    if (rep.band) setText("L1 Rep T", "Надёжность: " + (BAND_RU[rep.band] || rep.band));
    var anomLabel = isV2 ? (hl.erv_label || null) : hl.erv_label;
    if (anomLabel) {
      setText("L1 Anom T", anomLabel);
      var anomNode = el("L1 Anom T");
      if (anomNode && bandColor && LABEL_COLOR[bandColor]) {
        anomNode.style.color = LABEL_COLOR[bandColor];
      }
    }
  }

  function renderError() {
    setText("H Name", login);
    setText("H Meta", "Канал не найден или ещё не проанализирован");
    ["L1 Real", "L1 Shown", "L1 D1 T", "L1 D2 T", "L1 Total"].forEach(function (p) {
      setText(p, "—");
    });
  }

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
