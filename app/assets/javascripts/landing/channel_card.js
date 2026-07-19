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
  // erv_label_color (green|yellow|red) → the design's hero colour.
  var LABEL_COLOR = { green: "#25D9A4", yellow: "#F5C451", red: "#F0616D" };

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

    // Layer 1 — real vs shown. Reconcile all figures from ONE shown-base so real + bots = shown and
    // bot% = bots/shown, and so the card works both LIVE and OFFLINE:
    //   • LIVE  → shown = ccv (current snapshot); real = round(shown × erv%/100).
    //   • OFFLINE (ccv null — the common case) → back out shown from the last computed values:
    //     shown = erv_count / (erv%/100)  (i.e. the TIH's stored ccv the erv_count came from),
    //     real  = erv_count. Everything derives from real API fields (erv_count, erv_percent).
    // erv% (= TI) is the reliability signal. Falls back gracefully if erv% is missing (cold-start).
    var ervPct = hl.erv_percent;
    var live = !!hl.is_live && hl.ccv != null;
    var shown, real;
    if (live) {
      shown = hl.ccv;
      real = ervPct != null ? Math.round(shown * ervPct / 100) : hl.erv_count;
    } else if (hl.erv_count != null && ervPct != null && ervPct > 0) {
      real = hl.erv_count;
      shown = Math.round(real / (ervPct / 100));
    } else {
      real = hl.erv_count;
      shown = hl.ccv; // may be null → "—"
    }
    var bots = shown != null && real != null ? shown - real : null;
    var botPct = ervPct != null ? Math.round(100 - ervPct) : null;
    var realPct = ervPct != null ? Math.round(ervPct) : null;

    // Offline card is last-stream data, not "now" — keep the label honest.
    if (!live) setText("L1 Label", "РЕАЛЬНЫЕ ЗРИТЕЛИ · ПОСЛЕДНИЙ ЭФИР");

    setText("L1 Real", fmt(real));
    var realNode = el("L1 Real");
    if (realNode && hl.erv_label_color && LABEL_COLOR[hl.erv_label_color]) {
      realNode.style.color = LABEL_COLOR[hl.erv_label_color];
    }
    setText("L1 Shown", "/ " + fmt(shown) + " показано");
    setText("L1 D1 T", "−" + fmt(bots) + " боты / накрутка");
    setText("L1 D2 T", botPct != null ? "−" + botPct + "% от показанных" : "—");
    setText("L1 Total", "Всего показано Twitch: " + fmt(shown));
    setText(
      "Leg T bot",
      "Боты / накрутка " + fmt(bots) + " · " + (botPct != null ? botPct + "%" : "—")
    );
    setText("Leg T real", "Реальные " + fmt(real) + " · " + (realPct != null ? realPct + "%" : "—"));

    // Reliability band (reputation) + ERV anomaly label (headline, already RU + coloured).
    if (rep.band) setText("L1 Rep T", "Надёжность: " + (BAND_RU[rep.band] || rep.band));
    if (hl.erv_label) {
      setText("L1 Anom T", hl.erv_label);
      var anomNode = el("L1 Anom T");
      if (anomNode && hl.erv_label_color && LABEL_COLOR[hl.erv_label_color]) {
        anomNode.style.color = LABEL_COLOR[hl.erv_label_color];
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
