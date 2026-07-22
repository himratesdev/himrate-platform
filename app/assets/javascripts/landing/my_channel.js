// Streamer own-channel dashboard (screen 10) — wires the streamer's REAL channel analytics into the
// faithful Pencil export. Auth-gated: /api/v1/lk/status → /login. The channel is detected from
// GET /api/v1/user/me (twitch_login); a user without a linked Twitch sees an honest connect-CTA
// state (no samples). Data: public GET /channels/:login/card (headline + live_drill + reputation) +
// GET /channels/:login/trends/erv (free for the streamer on their own channel — ChannelPolicy).
//
// Honest deferrals: the «7 проверок» card is hidden — the engine has no per-signal verdicts (ADR
// DEC-3; same PO decision as the brand card layer-2, post-TI-v2 follow-up). «Чат/зритель» and
// «Новые аккаунты» stat cells are hidden (signal_breakdown values are normalized scores, not the
// raw ratios the design shows — showing a score as a ratio would be fake). Category has no field.
// CSP-safe external asset, same-origin cookie fetch, no eval.
(function () {
  "use strict";

  var BAND_RU = { impeccable: "Безупречная", stable: "Стабильная", variable: "Изменчивая", unstable: "Нестабильная" };
  var BAND_COLOR = { impeccable: "#25D9A4", stable: "#4FA9FF", variable: "#F6A823", unstable: "#FB4E55" };
  var GOOD_BANDS = { impeccable: true, stable: true };
  var CHART_BARS = 16, REP_BARS = 30;

  function q(root, name) { return (root || document).querySelector('[data-pencil-name="' + name + '"]'); }
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

  function statValue(cardName, value) {
    var card = q(document, cardName);
    if (!card) return;
    if (value == null) { hide(card); return; }
    setT(card, "Stat V", value);
  }

  // ---- non-linked state (honest CTA, no samples) ----
  function renderConnectState() {
    ["Hero · Реальные зрители", "Checks · 7 проверок", "Chart · ERV/CCV", "Reputation · 30 стримов"]
      .forEach(function (n) { hide(q(document, n)); });
    // fallback: hide by partial names present in this export
    ["Charts Row", "Chart Card"].forEach(function (n) { hide(q(document, n)); });
    var content = q(document, "Content") || document.body;
    var box = document.createElement("div");
    box.setAttribute("data-pencil-name", "ConnectState");
    box.style.cssText = "width:100%;padding:64px 24px;text-align:center;color:#C7C7D1;font-family:Inter,system-ui,sans-serif;";
    box.innerHTML =
      '<div style="font-size:18px;font-weight:700;margin-bottom:8px;">Привяжите Twitch, чтобы увидеть свой канал</div>' +
      '<div style="font-size:14px;color:#9A9AA9;max-width:480px;margin:0 auto 20px;">Дашборд стримера показывает реальную аудиторию, репутацию и динамику вашего канала. Войдите через Twitch — канал подтянется автоматически.</div>' +
      '<a href="/auth/web/twitch" style="display:inline-block;background:#7B5CFA;color:#fff;text-decoration:none;padding:11px 20px;border-radius:12px;font-weight:600;font-size:14px;">Войти через Twitch</a>';
    content.appendChild(box);
  }

  // ---- hero (card headline + live_drill) ----
  function renderHero(login, card) {
    var data = (card && card.data) || {};
    var channel = data.channel || {};
    var hl = (data.layers && data.layers.headline && data.layers.headline.data) || {};
    var drill = (data.layers && data.layers.live_drill && data.layers.live_drill.data) || null;
    var rep = (data.layers && data.layers.reputation && data.layers.reputation.data) || {};
    var band = rep.current && rep.current.band;

    setT(document, "Ch Name", channel.display_name || login);
    setT(document, "Ch Meta", "twitch.tv/" + (channel.login || login)); // category: no field
    setT(document, "H Sub", (channel.display_name || login) + " · " + (channel.login || login) +
      (hl.calculated_at ? " · обновлено " + String(hl.calculated_at).slice(11, 16) : ""));

    if (band) {
      setT(document, "Rel Label", BAND_RU[band] || band);
      var rl = q(document, "Rel Label"); if (rl) rl.style.color = BAND_COLOR[band] || "#9A9AA9";
    }

    // Real vs shown — v2 (post-cutover /card): authenticity = % real, erv = the native subtracted
    // real-viewer COUNT (ccv = shown V). v1 legacy: erv_percent + erv_count (backed out when offline).
    var isV2 = hl.engine_version === "v2";
    var erv = isV2 ? hl.authenticity : hl.erv_percent; // % real
    var ervCount = isV2 ? hl.erv : hl.erv_count;       // real-viewer count
    var real, shown;
    if (hl.is_live && hl.ccv != null) {
      shown = hl.ccv;
      real = ervCount != null ? ervCount : (erv != null ? Math.round(shown * erv / 100) : null);
    } else if (ervCount != null && erv > 0) {
      real = ervCount;
      shown = Math.round(real / (erv / 100));
    } else { real = ervCount; shown = hl.ccv; }

    setT(document, "Real Num", fmt(real));
    setT(document, "Shown Num", "/ " + fmt(shown));
    var diff = real != null && shown != null ? shown - real : null;
    var diffPct = erv != null ? Math.round(100 - erv) : null;
    // Legal-safe wording (v3 doctrine, matches channel_card.js): the app UI states the
    // neutral "скрытая разница … от показанных" — never "боты/накрутка" as a public
    // accusation. "Chip Bots T"/"Chip Bots" are Pencil DOM node names (the design
    // contract), NOT variable names — do NOT rename them or q() breaks.
    if (diff != null && diff > 0) setT(document, "Chip Bots T", "−" + fmt(diff) + " скрытая разница · −" + diffPct + "% от показанных");
    else hide(q(document, "Chip Bots"));
    if (ervCount != null) setT(document, "Chip ERV T", "ERV " + fmt(ervCount) + " вовлечены");
    else hide(q(document, "Chip ERV"));

    // Live anomaly banner — only from real live_drill alerts.
    var alerts = drill && drill.anomaly_alerts;
    if (alerts && alerts.length) {
      var a = alerts[0];
      setT(document, "Anomaly T", "Аномалия онлайна: " + (a.ccv_delta != null ? "+" + fmt(a.ccv_delta) : "") +
        (a.type ? " · " + a.type : ""));
    } else {
      hide(q(document, "Anomaly Tag"));
      hide(q(document, "Anomaly T"));
      hide(q(document, "Anomaly Icon"));
    }

    // Stats grid: CCV + ERV real; чат/зритель + новые аккаунты hidden (scores ≠ raw ratios).
    statValue("Stat Показано (CCV)", fmt(shown));
    statValue("Stat ERV · вовлечены", fmt(ervCount));
    statValue("Stat Чат / зритель", null);
    statValue("Stat Новые аккаунты", null);
  }

  // ---- ERV/CCV chart (trends/erv daily) ----
  function renderChart(login) {
    apiGet("/api/v1/channels/" + encodeURIComponent(login) + "/trends/erv?period=30d")
      .then(function (resp) {
        var d = (resp && resp.data) || {};
        var points = (d.points || []).slice(-CHART_BARS);
        if (!points.length) { hideChart(); return; }
        var max = Math.max.apply(null, points.map(function (p) { return p.ccv_avg || 0; }).concat([1]));
        for (var i = 0; i < CHART_BARS; i++) {
          var bar = q(document, "Bar " + i);
          if (!bar) continue;
          var p = points[i];
          var botSeg = q(bar, "Bot Seg"), realSeg = q(bar, "Real Seg");
          if (!p) { bar.style.opacity = "0.12"; if (botSeg) botSeg.style.height = "0px"; if (realSeg) realSeg.style.height = "2px"; continue; }
          var realH = Math.round(((p.erv_absolute || 0) / max) * 120);
          var botH = Math.round((Math.max((p.ccv_avg || 0) - (p.erv_absolute || 0), 0) / max) * 120);
          if (realSeg) realSeg.style.height = Math.max(realH, 2) + "px";
          if (botSeg) botSeg.style.height = botH + "px";
          bar.title = p.date + " · реальные " + fmt(p.erv_absolute) + " из " + fmt(p.ccv_avg);
        }
        if (d.summary) setT(document, "Chart Sub", "Средний ERV за 30 дней: " + Math.round(d.summary.average) + "%");
      })
      .catch(function () { hideChart(); });
  }
  function hideChart() {
    hide(q(document, "Chart · ERV/CCV"));
    hide(q(document, "Charts Row"));
  }

  // ---- reputation (30-stream trajectory) ----
  function renderReputation(login) {
    apiGet("/api/v1/channels/" + encodeURIComponent(login) + "/reputation/history")
      .then(function (resp) {
        var d = (resp && resp.data) || {};
        var traj = d.real_audience_trajectory || [];
        if (!traj.length) { hide(q(document, "Reputation · 30 стримов")); return; }

        var counts = {};
        for (var i = 0; i < REP_BARS; i++) {
          var pt = traj[i];
          var b1 = q(document, "RB1 " + i), b2 = q(document, "RB2 " + i);
          if (!pt) {
            if (b1) b1.style.backgroundColor = "#34343F";
            if (b2) { b2.style.backgroundColor = "#34343F"; b2.style.height = "6px"; }
            continue;
          }
          var band = pt.band;
          if (band) counts[band] = (counts[band] || 0) + 1;
          if (b1) b1.style.backgroundColor = BAND_COLOR[band] || "#34343F";
          if (b2) {
            var pct = Math.max(0, Math.min(100, pt.real_audience_pct || 0));
            b2.style.height = Math.max(4, Math.round(pct * 0.56)) + "px";
            b2.style.backgroundColor = "#7B5CFA";
            b2.title = (pt.ended_at ? String(pt.ended_at).slice(0, 10) + " · " : "") + Math.round(pct) + "% реальных";
          }
        }

        var good = (counts.impeccable || 0) + (counts.stable || 0);
        setT(document, "Verdict T", good + "/" + Math.min(traj.length, REP_BARS) + " в норме");

        // legend counts (RL Безупречная … anchors carry the RU band names)
        Object.keys(BAND_RU).forEach(function (band) {
          var leg = q(document, "RL " + BAND_RU[band]);
          if (leg) { var t = q(leg, "RL T"); if (t) t.textContent = BAND_RU[band] + " · " + (counts[band] || 0); }
        });

        // derived prose for block 2 — real avg ± spread of real_audience_pct
        var pcts = traj.map(function (p) { return p.real_audience_pct; }).filter(function (v) { return v != null; });
        if (pcts.length) {
          var avg = pcts.reduce(function (s, v) { return s + v; }, 0) / pcts.length;
          var spread = Math.max.apply(null, pcts) - Math.min.apply(null, pcts);
          setT(document, "Rep B2 Trend", "В среднем " + Math.round(avg) + "% реальных · разброс ±" + Math.round(spread / 2) + " п.п.");
        }
      })
      .catch(function () { hide(q(document, "Reputation · 30 стримов")); });
  }

  // ---- boot ----
  function boot() {
    // per-signal verdicts don't exist yet (ADR DEC-3, post-TI-v2) — never fake pass/flag pills
    hide(q(document, "Checks · 7 проверок"));

    apiGet("/api/v1/user/me")
      .then(function (resp) {
        var u = (resp && resp.data) || {};
        if (!u.twitch_linked || !u.twitch_login) { renderConnectState(); return; }
        var login = u.twitch_login;
        apiGet("/api/v1/channels/" + encodeURIComponent(login) + "/card")
          .then(function (card) { renderHero(login, card); })
          .catch(function () { renderConnectState(); });
        renderChart(login);
        renderReputation(login);
      })
      .catch(function () { renderConnectState(); });
  }

  fetch("/api/v1/lk/status", { headers: { Accept: "application/json" }, credentials: "same-origin" })
    .then(function (r) { return r.ok ? r.json() : {}; })
    .then(function (s) {
      if (!s || !s.authenticated) { window.location.href = "/login"; return; }
      boot();
    })
    .catch(function () { window.location.href = "/login"; });
})();
