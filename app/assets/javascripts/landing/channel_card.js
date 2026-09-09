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

    var drill = (layers.live_drill && layers.live_drill.data) || {};
    renderChecks(hl, drill);
    renderReputation(layers.reputation && layers.reputation.data);
    renderExplanation(drill);
  }

  // W2: real L2 — check rows driven by the REAL public /trust-headline signals (band verdict +
  // reason codes). The nine-entry RU map that used to live here is gone: the server resolves all
  // fourteen texts from config/locales/reason.*.yml (it carried one code the engine had stopped
  // emitting and silently dropped six it does emit).
  var STATE_COLOR = { ok: "#25D9A4", warn: "#F6A823", dim: "#9A9AA9" };

  function renderChecks(hl, drill) {
    var band = hl.band || {};
    var rows = [];
    var bandState = band.color === "green" ? "ok" : band.color === "grey" ? "dim" : "warn";
    // No verdict at all (error/empty scrub) → zero rows, everything hidden below.
    if (hl.erv_label || band.color) rows.push(["Вердикт эфира", hl.erv_label || "—", bandState]);
    ((drill && drill.reason_codes_detail) || []).forEach(function (r) {
      if (r && r.title) rows.push([r.title, r.text || "", r.tone || "dim"]);
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

  // ────────────────────────────────────────────────────────────────────────────
  // Blocks the Pencil export never had. There is no design frame for them yet, so they are built
  // in the card's own visual language (same card shell as "L1 Headline": #141419 on #25252F,
  // 20px radius, 28px padding) — the /graph precedent for a hand-built surface. When the frames
  // land these render functions are what the port replaces.
  // ────────────────────────────────────────────────────────────────────────────

  var CARD_CSS =
    "box-sizing:border-box;width:100%;display:flex;flex-direction:column;gap:16px;padding:28px;" +
    "background:#141419;border:1px solid #25252F;border-radius:20px;";
  var TITLE_CSS = "margin:0;color:#F4F4F6;font:600 17px Inter,system-ui,sans-serif;";
  var MUTED = "#9A9AA9";

  function mk(tag, css, text) {
    var n = document.createElement(tag);
    if (css) n.style.cssText = css;
    if (text != null) n.textContent = text;
    return n;
  }

  // Insert a section as a sibling of the headline card, keeping the Content column's flow.
  function mount(node, afterPencilName) {
    var anchor = el(afterPencilName);
    if (!anchor || !anchor.parentElement) return false;
    anchor.parentElement.insertBefore(node, anchor.nextSibling);
    return true;
  }

  // ── block 3 — the verdict, taken apart ─────────────────────────────────────
  // Renders the subtraction the engine actually did, including the rule it used to combine the
  // arms. It never draws a tidy waterfall: under the cumulative convention only the largest arm
  // is applied, and pretending otherwise would misstate the arithmetic.
  function renderExplanation(drill) {
    var e = drill && drill.explanation;
    if (!e) return;

    var box = mk("div", CARD_CSS);
    box.setAttribute("data-pencil-name", "Explain");
    box.appendChild(mk("h2", TITLE_CSS, "Из чего сложилась оценка"));

    var table = mk("div", "width:100%;display:flex;flex-direction:column;gap:10px;");
    table.appendChild(explainRow("Показано зрителей", fmt(e.shown), "#F4F4F6", null));

    (e.arms || []).forEach(function (arm) {
      var copy = ARM_COPY[arm.kind];
      if (!copy) return;
      var amount = arm.applied ? "−" + fmt(arm.amount) : fmt(arm.amount);
      var colour = arm.applied ? "#F0616D" : MUTED;
      table.appendChild(explainRow(copy.title, amount, colour, armDetail(arm, copy)));
    });

    var real = e.real || {};
    var span = real.lo != null && real.hi != null ? "диапазон " + fmt(real.lo) + "–" + fmt(real.hi) : null;
    table.appendChild(explainRow("Реальных зрителей", fmt(real.value), "#25D9A4", span));
    box.appendChild(table);

    var rule = e.fusion && e.fusion.mode === "sum"
      ? "Вычитания складываются: аккаунты с признаками автоматизации и молчаливая часть аудитории — это разные люди."
      : "Берётся наибольшее из вычитаний, чтобы одних и тех же зрителей не посчитать дважды.";
    box.appendChild(mk("p", "margin:0;color:" + MUTED + ";font:400 13px/1.55 Inter,system-ui,sans-serif;", rule));

    var facts = factChips(e);
    if (facts) box.appendChild(facts);

    mount(box, "L1 Headline");
  }

  var ARM_COPY = {
    named: { title: "Аккаунты с признаками автоматизации" },
    deficit: { title: "Недобор активности против нормы" },
    self_history: { title: "Расхождение с собственной историей канала" }
  };

  function explainRow(label, value, colour, note) {
    var row = mk("div", "width:100%;display:flex;flex-direction:column;gap:3px;");
    var top = mk("div", "width:100%;display:flex;flex-direction:row;gap:16px;justify-content:space-between;align-items:baseline;");
    top.appendChild(mk("span", "color:#C9C9D1;font:500 14.5px Inter,system-ui,sans-serif;", label));
    top.appendChild(mk("span", "color:" + colour + ";font:600 16px Inter,system-ui,sans-serif;white-space:nowrap;", value));
    row.appendChild(top);
    if (note) row.appendChild(mk("span", "color:" + MUTED + ";font:400 12.5px/1.5 Inter,system-ui,sans-serif;", note));
    return row;
  }

  function armDetail(arm) {
    if (arm.kind === "named" && arm.accounts != null) {
      return arm.accounts + " аккаунтов из писавших в чате" +
        (arm.share_of_chat_pct != null ? " — " + arm.share_of_chat_pct + "% чата" : "");
    }
    if (arm.kind === "deficit") {
      var o = arm.observed, x = arm.expected;
      if (!o) return null;
      var here = "здесь пишет каждый " + o.one_in + "-й зритель";
      if (!x) return here + "; сравнивать пока не с чем — для этой категории и размера нет измеренной нормы";
      var peers = "у похожих каналов — каждый " + x.one_in + "-й";
      return here + "; " + peers + (x.calibrated ? "" : " (норма пока приблизительная, не измеренная)");
    }
    return null;
  }

  // The measurements the subtraction rests on. Shown as plain sentences, not as raw coefficients.
  function factChips(e) {
    var chat = e.chat || {}, conf = e.confidence || {};
    var items = [];
    if (chat.writers_effective != null) items.push("в чате писали ≈ " + fmt(chat.writers_effective) + " человек");
    if (conf.interval_pct != null) items.push("ширина оценки " + conf.interval_pct + "% от показанного");
    if (conf.cold_start_tier === "basic") items.push("оценка предварительная");
    if (!items.length) return null;

    var wrap = mk("div", "width:100%;display:flex;flex-wrap:wrap;gap:8px;");
    items.forEach(function (t) {
      wrap.appendChild(mk("span",
        "padding:5px 10px;border-radius:999px;background:#1B1B22;border:1px solid #25252F;" +
        "color:#C9C9D1;font:400 12px Inter,system-ui,sans-serif;", t));
    });
    return wrap;
  }

  // ── block 4 — how the online moved during this broadcast ───────────────────
  // The answer to "I open a stream and there is nothing there". Two series over the last 30
  // minutes: what Twitch showed and what the engine counts as real. Fewer than two points means
  // there is nothing to draw — the block is not rendered at all rather than shown empty.
  var SERIES_W = 860, SERIES_H = 150, PAD = 6;

  function renderStreamChart(history) {
    var pts = (history && history.points) || [];
    if (pts.length < 2) return;

    var box = mk("div", CARD_CSS);
    box.setAttribute("data-pencil-name", "Stream Series");
    var head = mk("div", "width:100%;display:flex;justify-content:space-between;align-items:baseline;gap:16px;");
    head.appendChild(mk("h2", TITLE_CSS, "Ход эфира"));
    head.appendChild(mk("span", "color:" + MUTED + ";font:400 12.5px Inter,system-ui,sans-serif;",
      "последние 30 минут · " + pts.length + " измерений"));
    box.appendChild(head);

    var shown = pts.map(function (p) { return p.ccv; });
    var real = pts.map(function (p) { return p.erv_count; });
    var top = Math.max.apply(null, shown.concat(real).filter(function (v) { return v != null; }).concat([ 1 ]));

    var svg = document.createElementNS("http://www.w3.org/2000/svg", "svg");
    svg.setAttribute("viewBox", "0 0 " + SERIES_W + " " + SERIES_H);
    svg.setAttribute("preserveAspectRatio", "none");
    svg.style.cssText = "width:100%;height:150px;display:block;";
    svg.appendChild(polyline(shown, top, "#4B4B57", 1.5));
    svg.appendChild(polyline(real, top, "#25D9A4", 2));
    box.appendChild(svg);

    var legend = mk("div", "display:flex;gap:18px;flex-wrap:wrap;");
    legend.appendChild(legendItem("#4B4B57", "показано Twitch"));
    legend.appendChild(legendItem("#25D9A4", "реальные зрители"));
    box.appendChild(legend);

    var anomalies = (history.anomalies || []).slice(0, 5);
    if (anomalies.length) {
      var list = mk("div", "width:100%;display:flex;flex-direction:column;gap:6px;");
      list.appendChild(mk("span", "color:#C9C9D1;font:500 13.5px Inter,system-ui,sans-serif;", "Что происходило"));
      anomalies.forEach(function (a) {
        var when = a.timestamp ? new Date(a.timestamp).toLocaleTimeString("ru-RU", { hour: "2-digit", minute: "2-digit" }) : "";
        list.appendChild(mk("span", "color:" + MUTED + ";font:400 12.5px Inter,system-ui,sans-serif;",
          when + " · " + (ANOMALY_RU[a.type] || a.type)));
      });
      box.appendChild(list);
    }

    mount(box, "L1 Headline");
  }

  // Neutral names for the anomaly types the alerting layer emits — descriptions, never verdicts.
  var ANOMALY_RU = {
    viewbot_spike: "резкий скачок онлайна",
    anomaly_wave: "волна аномальной активности",
    ccv_step_function: "ступенчатое изменение онлайна",
    ccv_tier_clustering: "онлайн держится ровными ступенями",
    chat_behavior: "необычное поведение чата",
    chatter_ccv_ratio: "расхождение чата и онлайна",
    ccv_chat_correlation: "онлайн растёт, чат — нет",
    raid_bot: "приток с другого канала",
    host_raid: "рейд с другого канала",
    known_bot_match: "аккаунты из бот-реестров",
    ti_drop: "оценка резко снизилась",
    erv_divergence: "расхождение оценок"
  };

  function polyline(values, top, colour, width) {
    var line = document.createElementNS("http://www.w3.org/2000/svg", "polyline");
    var step = values.length > 1 ? (SERIES_W - PAD * 2) / (values.length - 1) : 0;
    var pts = [];
    values.forEach(function (v, i) {
      if (v == null) return;
      var y = SERIES_H - PAD - (v / top) * (SERIES_H - PAD * 2);
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

  // ── block 0 — coordination ring ────────────────────────────────────────────
  // Sits above everything because it outranks the channel's own verdict: it is evidence about a
  // GROUP of channels sharing one pool of accounts that post in three or more of them inside the
  // same five seconds.
  //
  // WORDING IS THE SERVER'S CALL. `headline` is "verdict" only when the ring's pool intersects the
  // engine's own hard named-bot evidence across at least two of its channels; otherwise it is
  // "observation" and the block states the numbers without naming anything. The client must never
  // upgrade one to the other.
  function renderCoordination(payload) {
    var d = (payload && payload.data) || {};
    if (!d.in_group || !d.group) return;
    var g = d.group;
    var verdict = g.headline === "verdict";
    var accent = verdict ? "#F0616D" : "#F6A823";

    var box = mk("div", CARD_CSS.replace("#25252F", accent + "66") +
      "background:linear-gradient(180deg," + accent + "14 0%,#141419 60%);");
    box.setAttribute("data-pencil-name", "Coordination");

    box.appendChild(mk("h2", "margin:0;color:" + accent + ";font:700 18px Inter,system-ui,sans-serif;",
      verdict ? "Признаки скоординированной накрутки чата"
              : "Скоординированная активность в нескольких каналах"));

    var others = Math.max(0, (g.member_count || 1) - 1);
    box.appendChild(mk("p", "margin:0;color:#E7E7EC;font:400 14px/1.6 Inter,system-ui,sans-serif;",
      "Аккаунтов, писавших в одни и те же секунды и здесь, и ещё в " + others +
      " каналах: " + fmt(g.accounts_shared) + ". Совместных срабатываний за " +
      (g.window_days || 7) + " дней: " + fmt(g.events) + "."));

    if (verdict && g.corroborated_accounts) {
      box.appendChild(mk("p", "margin:0;color:#C9C9D1;font:400 13px/1.55 Inter,system-ui,sans-serif;",
        "Из них " + fmt(g.corroborated_accounts) + " уже разобраны поимённо в " +
        g.corroborated_channels + " каналах группы."));
    }

    box.appendChild(memberChips(g.members || []));

    var actions = mk("div", "display:flex;gap:10px;flex-wrap:wrap;align-items:center;");
    var open = mk("button", btnCss(accent, true), "Разобрать");
    open.type = "button";
    var panel = mk("div", "width:100%;display:none;flex-direction:column;gap:14px;");
    open.addEventListener("click", function () {
      if (panel.style.display === "flex") { panel.style.display = "none"; open.textContent = "Разобрать"; return; }
      panel.style.display = "flex";
      open.textContent = "Свернуть";
      loadEvidence(g.id, panel);
    });
    actions.appendChild(open);

    var dispute = mk("a", btnCss("#3A3A46", false), "Оспорить");
    dispute.href = "mailto:support@himrate.com?subject=" +
      encodeURIComponent("Спор по скоординированной активности: " + login);
    actions.appendChild(dispute);

    var map = mk("a", btnCss("#3A3A46", false), "Открыть на карте");
    map.href = appHref("/graph?focus=" + encodeURIComponent(login));
    actions.appendChild(map);
    box.appendChild(actions);
    box.appendChild(panel);

    box.appendChild(mk("p", "margin:0;color:" + MUTED + ";font:400 11.5px/1.5 Inter,system-ui,sans-serif;",
      "Окно наблюдения " + (g.window_days || 7) + " дней; учитываются аккаунты, писавшие в 3+ каналах внутри 5 секунд. " +
      "Источник — архив чата наблюдаемых каналов. Обновлено: " + shortDate(g.computed_at) + "."));

    var content = el("Content");
    var first = el("Breadcrumb");
    if (content) content.insertBefore(box, first && first.nextSibling ? first.nextSibling : content.firstChild);
  }

  function btnCss(colour, filled) {
    return "display:inline-flex;align-items:center;padding:8px 14px;border-radius:10px;cursor:pointer;" +
      "font:600 13px Inter,system-ui,sans-serif;text-decoration:none;border:1px solid " + colour + ";" +
      (filled ? "background:" + colour + ";color:#0B0B0F;" : "background:transparent;color:#C9C9D1;");
  }

  function memberChips(members) {
    var wrap = mk("div", "width:100%;display:flex;flex-wrap:wrap;gap:8px;");
    members.forEach(function (m) {
      var chip = mk(m.is_focus ? "span" : "a",
        "display:inline-flex;align-items:center;gap:7px;padding:5px 11px 5px 6px;border-radius:999px;" +
        "background:#1B1B22;border:1px solid " + (m.is_focus ? "#3A3A46" : "#25252F") + ";" +
        "color:" + (m.is_focus ? "#F4F4F6" : "#C9C9D1") + ";font:500 12.5px Inter,system-ui,sans-serif;" +
        "text-decoration:none;");
      chip.appendChild(mk("span", "width:8px;height:8px;border-radius:50%;background:" +
        (LABEL_COLOR[m.band] || "#9A9AA9") + ";"));
      chip.appendChild(mk("span", "", m.login + (m.is_focus ? " · этот канал" : "")));
      if (!m.is_focus) chip.href = "/c/" + encodeURIComponent(m.login);
      wrap.appendChild(chip);
    });
    return wrap;
  }

  // The evidence table. Loaded on demand — it is the heaviest part of the payload and most
  // readers stop at the headline.
  function loadEvidence(groupId, panel) {
    if (panel.dataset.loaded === "1") return;
    panel.dataset.loaded = "1";
    panel.appendChild(mk("span", "color:" + MUTED + ";font:400 13px Inter,system-ui,sans-serif;", "Загружаем доказательства…"));

    fetch("/api/v1/coordination/groups/" + encodeURIComponent(groupId) +
          "?focus=" + encodeURIComponent(login),
          { headers: { Accept: "application/json" }, credentials: "same-origin" })
      .then(function (r) { if (!r.ok) throw new Error("HTTP " + r.status); return r.json(); })
      .then(function (body) { panel.textContent = ""; renderEvidence((body && body.data) || {}, panel); })
      .catch(function () {
        panel.textContent = "";
        panel.appendChild(mk("span", "color:" + MUTED + ";font:400 13px Inter,system-ui,sans-serif;",
          "Доказательства сейчас недоступны."));
        panel.dataset.loaded = "0";
      });
  }

  function renderEvidence(g, panel) {
    var ties = (g.edges || []).slice(0, 6);
    if (ties.length) {
      var t = mk("div", "width:100%;display:flex;flex-direction:column;gap:6px;");
      t.appendChild(mk("span", "color:#C9C9D1;font:500 13.5px Inter,system-ui,sans-serif;", "Самые плотные связи"));
      ties.forEach(function (e) {
        t.appendChild(mk("span", "color:" + MUTED + ";font:400 12.5px Inter,system-ui,sans-serif;",
          e.a + " ↔ " + e.b + " · общих аккаунтов " + fmt(e.accounts_shared)));
      });
      panel.appendChild(t);
    }

    var rows = (g.accounts || []).slice(0, 20);
    if (!rows.length) return;
    var head = mk("div", "width:100%;display:flex;flex-direction:column;gap:6px;");
    head.appendChild(mk("span", "color:#C9C9D1;font:500 13.5px Inter,system-ui,sans-serif;",
      "Аккаунты пула — показаны " + rows.length + " из " + fmt(g.accounts_shared)));
    rows.forEach(function (a) {
      var line = mk("div", "width:100%;display:flex;gap:14px;justify-content:space-between;" +
        "padding:6px 0;border-bottom:1px solid #1F1F27;font:400 12.5px Inter,system-ui,sans-serif;color:" + MUTED + ";");
      var left = mk("span", "color:#E7E7EC;", a.username + (a.named_bot ? " ·" : ""));
      if (a.named_bot) left.appendChild(mk("span", "color:#F0616D;", " разобран поимённо"));
      line.appendChild(left);
      line.appendChild(mk("span", "white-space:nowrap;",
        "каналов " + a.channels_in_group + " · срабатываний " + fmt(a.events) + rhythmNote(a)));
      head.appendChild(line);
    });
    panel.appendChild(head);
  }

  // Posting rhythm in words. A coefficient of variation near zero means the gaps between messages
  // barely differ — a metronome. Above ~1.5 the account writes the way a person does.
  function rhythmNote(a) {
    if (a.median_interval_sec == null) return "";
    var cv = a.interval_cv;
    var how = cv == null ? "" : cv < 0.5 ? ", очень ровно" : cv < 1.5 ? ", ровно" : "";
    return " · каждые ≈" + Math.round(a.median_interval_sec) + " с" + how;
  }

  function shortDate(iso) {
    if (!iso) return "—";
    try {
      return new Date(iso).toLocaleString("ru-RU", { day: "2-digit", month: "2-digit", hour: "2-digit", minute: "2-digit" });
    } catch (e) { return "—"; }
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

  // Two independent surfaces, two independent fetches: neither the ring nor the broadcast series
  // may take the card down with it. A failure here leaves the block unrendered — an absent block
  // is honest, a broken card is not.
  function loadOptional(url, render) {
    fetch(url, { headers: { Accept: "application/json", "Accept-Language": "ru" }, credentials: "same-origin" })
      .then(function (r) { return r.ok ? r.json() : null; })
      .then(function (body) { if (body) render(body); })
      .catch(function (e) { if (window.console) console.warn("[channel_card] optional block:", url, e); });
  }

  loadOptional("/api/v1/channels/" + encodeURIComponent(login) + "/coordination", renderCoordination);
  loadOptional("/api/v1/channels/" + encodeURIComponent(login) + "/trust/history?period=30m",
               function (body) { renderStreamChart((body && body.data) || {}); });
})();
