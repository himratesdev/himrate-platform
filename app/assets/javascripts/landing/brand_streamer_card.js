// Brand dashboard streamer card (screen 21) — wires REAL 30-day track-record verification into the
// faithful Pencil export. Auth-gated: /api/v1/lk/status (httpOnly cookie) → /login when unauthenticated,
// brand paywall on 403. Data from the brand-gated GET /api/v1/brand/streamers/:login/card (4 layers
// composed from the live engine, no mocks; anything the engine can't back is in `deferred`).
//
// Layer-2 (authenticity) note (PO decision 2026-07-20): the design shows a per-check verdict for each
// of 7 checks, but the engine deliberately provides NO per-signal verdict (ADR DEC-3 — non-uniform
// signal semantics). So we DON'T fabricate ✓/⚠ per check: the section leads with the REAL overall
// classification + Trust Index, per-check verdict badges are hidden, backed checks show a factual line,
// deferred checks show "Скоро". CSP-safe external asset, same-origin fetch, no eval.
(function () {
  "use strict";

  // /app/streamers/:login → login
  var parts = window.location.pathname.split("/").filter(Boolean);
  var login = parts.length ? decodeURIComponent(parts[parts.length - 1]) : null;

  var BAND_RU = { impeccable: "Безупречная", stable: "Стабильная", variable: "Изменчивая", unstable: "Нестабильная" };
  var BAND_COLOR = { impeccable: "#25D9A4", stable: "#4FA9FF", variable: "#F6A823", unstable: "#FB4E55" };
  function tiColor(ti) {
    if (ti == null || isNaN(ti)) return "#9A9AA9";
    if (ti >= 80) return "#25D9A4";
    if (ti >= 50) return "#F5C451";
    return "#F0616D";
  }
  // Per-design-check → treatment. "score" = feeds the Trust Index (factual, no verdict); "anomalies"
  // = real anomaly count; "deferred" = no engine source (mirrors card `deferred`).
  var CHECK_MAP = {
    "Check · Соотношение чат / зрители": "score",
    "Check · Источники трафика": "deferred",
    "Check · Динамика фолловеров": "score",
    "Check · География аудитории": "deferred",
    "Check · Сетевые сигнатуры": "score",
    "Check · Синхронные всплески": "anomalies",
    "Check · Удержание сессий": "deferred",
  };

  function q(root, name) { return (root || document).querySelector('[data-pencil-name="' + name + '"]'); }
  function setText(root, name, t) { var n = q(root, name); if (n != null && t != null) n.textContent = t; }
  function hide(root, name) { var n = q(root, name); if (n) n.style.display = "none"; }
  function dim(el) { if (el) { el.style.opacity = "0.4"; el.style.pointerEvents = "none"; el.title = "Скоро"; } }
  function fmt(n) {
    if (n == null || isNaN(n)) return "—";
    return Math.round(n).toString().replace(/\B(?=(\d{3})+(?!\d))/g, " ");
  }
  function initials(s) { s = (s || "").replace(/[^A-Za-zА-Яа-я0-9]/g, ""); return (s.slice(0, 2) || "?").toUpperCase(); }

  function render(resp) {
    var d = (resp && resp.data) || {};
    renderHeader(d);
    renderLayer1(d);
    renderLayer2(d.layer2_authenticity || {});
    renderLayer3(d.layer3_reputation || {});
    hideDeferredVisuals();
  }

  function renderHeader(d) {
    var ch = d.channel || {};
    setText(document, "Av T", initials(ch.display_name || login));
    setText(document, "Name", ch.display_name || login);
    setText(document, "Handle", "twitch.tv/" + (ch.login || login));
    setText(document, "Cat", ch.category || "—");
    setText(document, "Lang", ch.language || "—");

    // Header reputation band badge.
    var rep = d.layer3_reputation || {};
    if (rep.band) {
      setText(document, "TB Label", rep.band_label_ru || BAND_RU[rep.band] || rep.band);
      var dot = q(document, "TB Dot"); if (dot) dot.style.backgroundColor = BAND_COLOR[rep.band] || "#9A9AA9";
      var lbl = q(document, "TB Label"); if (lbl) lbl.style.color = BAND_COLOR[rep.band] || "#9A9AA9";
    } else {
      hide(document, "Trust · Стабильная");
    }
    // Legal-loaded "точно не бот" badge — hidden (the real verdict lives in the authenticity section).
    hide(document, "Verified");

    // Chips: streams in the window is real; history-depth is deferred.
    var win = d.window || {};
    setText(document, "Chip · Эфиров: 11 / мес", "Эфиров: " + (win.streams != null ? win.streams : "—") + " / 30 дн");
    hide(document, "Chip · Глубина истории: 14 мес");

    // Actions — both deferred (pdf_export / add_to_campaign).
    dim(q(document, "Btn · Скачать отчёт"));
    dim(q(document, "Btn · Добавить в кампанию"));
  }

  function renderLayer1(d) {
    var l1 = d.layer1_real_audience || {};
    if (l1.available === false) {
      setText(document, "Big", "—");
      setText(document, "HL2", "Недостаточно данных за 30 дней");
      hide(document, "Delta");
    } else {
      setText(document, "Big", fmt(l1.real_avg_viewers));
      var big = q(document, "Big");
      var l2h = d.layer2_authenticity || {};
      var ti = l2h.authenticity != null ? l2h.authenticity : l2h.ti_score;
      if (big) big.style.color = tiColor(ti);
      setText(document, "HL2", "из " + fmt(l1.shown_avg_viewers) + " на витрине Twitch");
      var corr = l1.bot_correction_pct == null ? null : Math.abs(l1.bot_correction_pct);
      if (corr == null || corr < 1) hide(document, "Delta");
      else setText(document, "DT", "−" + Math.round(corr) + "% бот-коррекция");
    }

    // Anomaly banner — real layer-5. Hide when there are none.
    var anomalies = d.layer5_anomalies || [];
    if (!anomalies.length) {
      hide(document, "Anomaly");
    } else {
      var a = anomalies[0];
      var when = a.at ? a.at.slice(0, 10) : "";
      setText(document, "An T", "Аномалия" + (when ? " " + when : "") + " · " + (a.cause || a.type || "исключена из среднего") +
        (anomalies.length > 1 ? " (+" + (anomalies.length - 1) + " ещё)" : ""));
      hide(document, "An Link"); // "Разобрать" detail view is deferred
    }
    // Submetrics (peak / median-chat / repeat-viewer) have no honest 30-day source → hidden.
    hide(document, "Submetrics");
  }

  function renderLayer2(l2) {
    setText(document, "CHH T", "Подлинность аудитории");
    if (l2.available === false) {
      setText(document, "CHH S", "Недостаточно данных для анализа сигналов");
      hide(document, "Checks List");
      hide(document, "Checks Sum");
      return;
    }
    // Dual-contract (PR3b TI v2): v2 layer2 carries {authenticity, band{color}, reason_codes};
    // v1 carries {ti_score, classification, checks}.
    var isV2 = l2.basis === "trust_index_history.v2" || l2.authenticity != null;
    var scalar = isV2 ? l2.authenticity : l2.ti_score;
    var checksCount = isV2 ? (l2.reason_codes || []).length : l2.checks_total;
    setText(document, "CHH S", isV2
      ? ("Подлинность " + (scalar != null ? Math.round(scalar) + "%" : "—") + " · " + ((l2.reason_codes || []).length) + " факторов")
      : ("Проанализировано " + (l2.checks_total != null ? l2.checks_total : "—") +
        " сигналов подлинности · Индекс доверия (TI) " + (l2.ti_score != null ? Math.round(l2.ti_score) : "—")));

    // Summary pills → REAL overall verdict. v2: engine band colour + i18n'd band verdict.
    var label = isV2 ? bandLabel(l2.band) : classificationLabel(l2.classification);
    var color = isV2 ? bandHex(l2.band) : tiColor(l2.ti_score);
    var p1 = q(document, "MP · 6 в норме");
    if (p1) { setText(p1, "MP T", label); var d1 = q(p1, "MP D"); if (d1) d1.style.backgroundColor = color; var t1 = q(p1, "MP T"); if (t1) t1.style.color = color; }
    var p2 = q(document, "MP · 1 внимание");
    if (p2) {
      setText(p2, "MP T", (checksCount != null ? checksCount : "—") + (isV2 ? " факторов" : " сигналов"));
      var d2 = q(p2, "MP D"); if (d2) d2.style.backgroundColor = "#5E5E6B";
      var t2 = q(p2, "MP T"); if (t2) t2.style.color = "#9A9AA9";
    }

    var anomalyCount = (window.__cardAnomalyCount != null) ? window.__cardAnomalyCount : 0;
    Object.keys(CHECK_MAP).forEach(function (anchor) {
      var rowEl = q(document, anchor);
      if (!rowEl) return;
      // No per-check verdict from the engine (ADR DEC-3) → hide the fabricatable badge.
      hide(rowEl, "V I");
      hide(rowEl, "V T");
      var kind = CHECK_MAP[anchor];
      if (kind === "deferred") {
        setText(rowEl, "CK D", "Скоро");
        rowEl.style.opacity = "0.5";
      } else if (kind === "anomalies") {
        setText(rowEl, "CK D", anomalyCount ? anomalyCount + " аномалий за 30 дней" : "Аномалий не обнаружено");
      } else {
        setText(rowEl, "CK D", "Учтено в Индексе доверия");
      }
    });
  }

  var BAND_HEX = { green: "#25D9A4", yellow: "#F5C451", red: "#F0616D", grey: "#9A9AA9", amber: "#F6A823" };
  function bandHex(band) { return (band && BAND_HEX[band.color]) || "#9A9AA9"; }
  function bandLabel(band) {
    // Mirrors config/locales/band.ru.yml (legal-safe 6-row verdicts).
    var map = {
      "band.red_significant": "Значительная аномалия онлайна",
      "band.yellow_anomaly": "Аномалия онлайна",
      "band.green_real": "Аудитория реальная",
      "band.green_no_anomaly": "Аномалий не замечено",
      "band.grey_insufficient": "Недостаточно данных",
      "band.amber_exceeds": "Онлайн выше наблюдаемой активности",
    };
    return (band && map[band.label_key]) || "—";
  }

  function classificationLabel(c) {
    // Legal-safe RU labels aligned with the ERV/TI verdict wording.
    switch (c) {
      case "trusted": return "Аудитория реальная";
      case "needs_review": return "Требует внимания";
      case "suspicious": return "Аномалия аудитории";
      case "fraudulent": return "Значительная аномалия";
      default: return "—";
    }
  }

  function renderLayer3(l3) {
    if (l3.tier != null) setText(document, "Score V", Math.round(l3.tier));
    else setText(document, "Score V", "—");
    setText(document, "PR T", "Репутация: " + (l3.band_label_ru || BAND_RU[l3.band] || "—"));

    // Dispute is state-changing → the "Заспорить оценку" button is deferred (dispute_write).
    dim(q(document, "Prove Btn"));

    // Dispute status block — show only when there is an open dispute.
    if (l3.dispute && l3.dispute.status) {
      setText(document, "Disp T", "Спор стримера · " + (l3.dispute.status === "reviewing" ? "на пересмотре" : "на рассмотрении"));
      setText(document, "Disp D", "Канал оспорил оценку — до пересмотра показана текущая оценка.");
    } else {
      hide(document, "Disp Col");
      hide(document, "Dispute");
    }
    // 12-month reputation bars have no honest per-month series in this contract → hide the sample bars.
    hide(document, "Rep Bars");
  }

  // Deferred whole-sections / Pro-gated panels (no engine backing) — hidden honestly.
  function hideDeferredVisuals() {
    ["Layer 4", "Gate Banner", "Profile Platforms", "Panel · Покрытие аудитории", "Panel · История и глубина", "Overlap List"]
      .forEach(function (a) { hide(document, a); });
  }

  // ---- paywall / not-found / error ----
  function fullScreenMsg(html) {
    var content = q(document, "Content") || q(document, "Main Col") || document.body;
    Array.prototype.slice.call(content.querySelectorAll(
      '[data-pencil-name="Profile Header"], [data-pencil-name="Main Row"]'
    )).forEach(function (n) { n.style.display = "none"; });
    var old = q(document, "MsgState"); if (old) old.remove();
    var box = document.createElement("div");
    box.setAttribute("data-pencil-name", "MsgState");
    box.style.cssText = "width:100%;padding:64px 24px;text-align:center;color:#C7C7D1;font-family:Inter,system-ui,sans-serif;";
    box.innerHTML = html;
    content.appendChild(box);
  }
  function renderNotFound() {
    fullScreenMsg('<div style="font-size:18px;font-weight:700;margin-bottom:8px;">Стример не найден</div>' +
      '<div style="font-size:14px;color:#9A9AA9;max-width:460px;margin:0 auto 20px;">Канал «' + (login || "") + '» ещё не проанализирован или не существует.</div>' +
      '<a href="/app/search" style="display:inline-block;background:#7B5CFA;color:#fff;text-decoration:none;padding:11px 20px;border-radius:12px;font-weight:600;font-size:14px;">К поиску стримеров</a>');
  }
  function renderPaywall() {
    fullScreenMsg('<div style="font-size:18px;font-weight:700;margin-bottom:8px;">Карточка стримера — для бренд-аккаунтов</div>' +
      '<div style="font-size:14px;color:#9A9AA9;max-width:460px;margin:0 auto 20px;">Проверка стримера за 30 дней доступна на бизнес-тарифе.</div>' +
      '<a href="/brands" style="display:inline-block;background:#7B5CFA;color:#fff;text-decoration:none;padding:11px 20px;border-radius:12px;font-weight:600;font-size:14px;">Узнать о бренд-тарифах</a>');
  }

  function load() {
    if (!login) { renderNotFound(); return; }
    fetch("/api/v1/brand/streamers/" + encodeURIComponent(login) + "/card", {
      headers: { Accept: "application/json", "Accept-Language": "ru" }, credentials: "same-origin",
    })
      .then(function (r) {
        if (r.status === 403) { renderPaywall(); return null; }
        if (r.status === 404) { renderNotFound(); return null; }
        if (!r.ok) throw new Error("HTTP " + r.status);
        return r.json();
      })
      .then(function (resp) {
        if (!resp) return;
        var d = (resp && resp.data) || {};
        window.__cardAnomalyCount = (d.layer5_anomalies || []).length;
        render(resp);
      })
      .catch(function (e) {
        if (window.console) console.warn("[brand_streamer_card] load failed:", e);
        fullScreenMsg('<div style="font-size:15px;color:#9A9AA9;">Не удалось загрузить карточку. Попробуйте позже.</div>');
      });
  }

  fetch("/api/v1/lk/status", { headers: { Accept: "application/json" }, credentials: "same-origin" })
    .then(function (r) { return r.ok ? r.json() : {}; })
    .then(function (s) {
      if (!s || !s.authenticated) { window.location.href = "/login"; return; }
      load();
    })
    .catch(function () { window.location.href = "/login"; });
})();
