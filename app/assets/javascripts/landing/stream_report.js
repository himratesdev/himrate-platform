// One broadcast, taken apart (WEB-CONSOLIDATION §8). Reads
// GET /api/v1/channels/:login/streams/:stream_id/report — an endpoint that has returned a full
// per-broadcast picture (minute series, anomalies, raids, chat stats) for months and was rendered
// on no page at all. Built in the card's design language; there is no Pencil frame for it yet.
// CSP-safe: external asset, same-origin fetch, no eval.
(function () {
  "use strict";

  // /c/:login/s/:stream_id
  var parts = window.location.pathname.split("/").filter(Boolean);
  if (parts.length < 4) return;
  var login = decodeURIComponent(parts[1]);
  var streamId = decodeURIComponent(parts[3]);

  var CARD =
    "box-sizing:border-box;width:100%;display:flex;flex-direction:column;gap:16px;padding:28px;" +
    "background:#141419;border:1px solid #25252F;border-radius:20px;";
  var TITLE = "margin:0;color:#F4F4F6;font:600 17px Inter,system-ui,sans-serif;";
  var MUTED = "#9A9AA9";
  var BAND_COLOR = { green: "#25D9A4", yellow: "#F5C451", red: "#F0616D", grey: "#9A9AA9", amber: "#F6A823" };
  var W = 900, H = 170, PAD = 6;

  function el(name) { return document.querySelector('[data-pencil-name="' + name + '"]'); }
  function mk(tag, css, text) {
    var n = document.createElement(tag);
    if (css) n.style.cssText = css;
    if (text != null) n.textContent = text;
    return n;
  }
  function fmt(n) {
    if (n == null || isNaN(n)) return "—";
    return Math.round(n).toString().replace(/\B(?=(\d{3})+(?!\d))/g, " ");
  }
  function hhmm(iso) {
    try { return new Date(iso).toLocaleTimeString("ru-RU", { hour: "2-digit", minute: "2-digit" }); }
    catch (e) { return ""; }
  }

  function render(body) {
    var d = (body && body.data) || {};
    var content = el("Content");
    if (!content) return;

    renderVerdict(d);
    if (d.ccv_timeline && d.ccv_timeline.length > 1) content.appendChild(series(d.ccv_timeline));
    var facts = chatFacts(d);
    if (facts) content.appendChild(facts);
    if ((d.anomalies || []).length) content.appendChild(eventList("Что происходило", d.anomalies.map(anomalyLine)));
    if ((d.raids || []).length) content.appendChild(eventList("Притоки с других каналов", d.raids.map(raidLine)));
    content.appendChild(backLink());
  }

  // The head card already carries the channel and the date; fill in the outcome.
  function renderVerdict(d) {
    var ti = d.trust_index || {};
    var stream = d.stream || {};
    var node = el("SR Verdict");
    if (!node) return;
    node.textContent = "";

    var band = ti.band || {};
    var colour = BAND_COLOR[band.color] || MUTED;
    var line = mk("div", "display:flex;flex-wrap:wrap;gap:10px 22px;align-items:baseline;");
    line.appendChild(mk("span", "color:" + colour + ";font:600 20px Inter,system-ui,sans-serif;",
      ti.erv != null ? fmt(ti.erv) + " реальных зрителей" : "оценка недоступна"));
    if (stream.peak_ccv != null) {
      line.appendChild(mk("span", "color:" + MUTED + ";font:400 13.5px Inter,system-ui,sans-serif;",
        "пик показанных " + fmt(stream.peak_ccv)));
    }
    if (stream.duration_ms) {
      line.appendChild(mk("span", "color:" + MUTED + ";font:400 13.5px Inter,system-ui,sans-serif;",
        "длительность " + Math.round(stream.duration_ms / 3600000 * 10) / 10 + " ч"));
    }
    node.appendChild(line);

    if (ti.confirmed_anomaly) {
      node.appendChild(mk("div", "margin-top:6px;color:" + colour + ";font:400 13px Inter,system-ui,sans-serif;",
        "Аномалия подтверждена независимым признаком."));
    }
  }

  // Shown vs real over the whole broadcast. The report caps the series at 500 points server-side.
  function series(timeline) {
    var box = mk("div", CARD);
    var head = mk("div", "width:100%;display:flex;justify-content:space-between;align-items:baseline;gap:16px;");
    head.appendChild(mk("h2", TITLE, "Как менялся онлайн"));
    head.appendChild(mk("span", "color:" + MUTED + ";font:400 12.5px Inter,system-ui,sans-serif;",
      timeline.length + " измерений за эфир"));
    box.appendChild(head);

    var shown = timeline.map(function (p) { return p.ccv; });
    var real = timeline.map(function (p) { return p.real_viewers; });
    var top = Math.max.apply(null, shown.concat(real).filter(function (v) { return v != null; }).concat([ 1 ]));

    var svg = document.createElementNS("http://www.w3.org/2000/svg", "svg");
    svg.setAttribute("viewBox", "0 0 " + W + " " + H);
    svg.setAttribute("preserveAspectRatio", "none");
    svg.style.cssText = "width:100%;height:170px;display:block;";
    svg.appendChild(polyline(shown, top, "#4B4B57", 1.5));
    svg.appendChild(polyline(real, top, "#25D9A4", 2));
    box.appendChild(svg);

    var legend = mk("div", "display:flex;gap:18px;flex-wrap:wrap;");
    legend.appendChild(legendItem("#4B4B57", "показано Twitch"));
    legend.appendChild(legendItem("#25D9A4", "реальные зрители"));
    legend.appendChild(mk("span", "color:" + MUTED + ";font:400 12.5px Inter,system-ui,sans-serif;",
      "по вертикали — зрители, максимум " + fmt(top)));
    box.appendChild(legend);
    return box;
  }

  function polyline(values, top, colour, width) {
    var line = document.createElementNS("http://www.w3.org/2000/svg", "polyline");
    var step = values.length > 1 ? (W - PAD * 2) / (values.length - 1) : 0;
    var pts = [];
    values.forEach(function (v, i) {
      if (v == null) return;
      var y = H - PAD - (v / top) * (H - PAD * 2);
      pts.push((PAD + i * step).toFixed(1) + "," + y.toFixed(1));
    });
    line.setAttribute("points", pts.join(" "));
    line.setAttribute("fill", "none");
    line.setAttribute("stroke", colour);
    line.setAttribute("stroke-width", String(width));
    line.setAttribute("stroke-linejoin", "round");
    return line;
  }

  function legendItem(colour, label) {
    var wrap = mk("span", "display:inline-flex;align-items:center;gap:7px;color:" + MUTED +
      ";font:400 12.5px Inter,system-ui,sans-serif;");
    wrap.appendChild(mk("span", "width:16px;height:2px;border-radius:2px;background:" + colour + ";"));
    wrap.appendChild(mk("span", "", label));
    return wrap;
  }

  function chatFacts(d) {
    var c = d.chat_stats || {};
    var items = [];
    if (c.unique_chatters != null) items.push("писавших в чате " + fmt(c.unique_chatters));
    if (c.total_messages != null) items.push("сообщений " + fmt(c.total_messages));
    if (c.ccv_avg != null) items.push("средний онлайн " + fmt(c.ccv_avg));
    if (!items.length) return null;

    var box = mk("div", CARD);
    box.appendChild(mk("h2", TITLE, "Чат за эфир"));
    var wrap = mk("div", "display:flex;flex-wrap:wrap;gap:8px;");
    items.forEach(function (t) {
      wrap.appendChild(mk("span",
        "padding:5px 10px;border-radius:999px;background:#1B1B22;border:1px solid #25252F;" +
        "color:#C9C9D1;font:400 12px Inter,system-ui,sans-serif;", t));
    });
    box.appendChild(wrap);
    return box;
  }

  function eventList(title, lines) {
    var box = mk("div", CARD);
    box.appendChild(mk("h2", TITLE, title));
    var list = mk("div", "width:100%;display:flex;flex-direction:column;gap:2px;");
    lines.slice(0, 25).forEach(function (t) {
      list.appendChild(mk("div", "padding:8px 0;border-bottom:1px solid #1F1F27;color:#C9C9D1;" +
        "font:400 13px Inter,system-ui,sans-serif;", t));
    });
    box.appendChild(list);
    return box;
  }

  // Neutral descriptions — the scale never accuses, and neither does this list.
  var ANOMALY_RU = {
    viewbot_spike: "резкий скачок онлайна",
    anomaly_wave: "волна аномальной активности",
    ccv_step_function: "ступенчатое изменение онлайна",
    ccv_tier_clustering: "онлайн держится ровными ступенями",
    chat_behavior: "необычное поведение чата",
    chatter_ccv_ratio: "расхождение чата и онлайна",
    ccv_chat_correlation: "онлайн растёт, чат — нет",
    auth_ratio: "необычный состав чата",
    follow_bot: "всплеск подписок",
    raid_bot: "приток с другого канала",
    host_raid: "рейд с другого канала",
    chat_bot: "автоматическая активность в чате",
    known_bot_match: "аккаунты из бот-реестров",
    account_profile_scoring: "необычные профили зрителей",
    cross_channel_presence: "зрители сразу в нескольких каналах",
    organic_spike: "органический всплеск",
    ti_drop: "оценка резко снизилась",
    erv_divergence: "расхождение оценок"
  };

  function anomalyLine(a) {
    var when = a.timestamp ? hhmm(a.timestamp) + " · " : "";
    var impact = a.ccv_impact != null ? " · онлайн " + (a.ccv_impact > 0 ? "+" : "") + fmt(a.ccv_impact) : "";
    return when + (ANOMALY_RU[a.type] || a.type) + impact;
  }

  function raidLine(r) {
    var when = r.timestamp ? hhmm(r.timestamp) + " · " : "";
    return when + "пришло " + fmt(r.viewers) + " зрителей" +
      (r.is_bot_raid ? " · приток с признаками автоматизации" : "");
  }

  function backLink() {
    var a = mk("a", "color:#A78BFA;font:500 13.5px Inter,system-ui,sans-serif;text-decoration:none;",
      "← Все данные о канале " + login);
    a.href = "/c/" + encodeURIComponent(login);
    return a;
  }

  function renderFailure() {
    var node = el("SR Verdict");
    if (node) node.textContent = "Разбор этого эфира сейчас недоступен.";
    var content = el("Content");
    if (content) content.appendChild(backLink());
  }

  fetch("/api/v1/channels/" + encodeURIComponent(login) + "/streams/" + encodeURIComponent(streamId) + "/report",
        { headers: { Accept: "application/json", "Accept-Language": "ru" }, credentials: "same-origin" })
    .then(function (r) { if (!r.ok) throw new Error("HTTP " + r.status); return r.json(); })
    .then(render)
    .catch(function (e) {
      if (window.console) console.warn("[stream_report] load failed:", e);
      renderFailure();
    });
})();
