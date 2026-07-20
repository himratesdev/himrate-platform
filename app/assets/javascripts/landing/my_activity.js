// Viewer personal activity (screen 03, PVA M-modules) — wires the viewer's REAL analytics into the
// faithful Pencil export. Auth-gated: /api/v1/lk/status (httpOnly cookie) → /login when
// unauthenticated. Data: GET /api/v1/me/analytics/{overview,communities,supporter,reflection,
// patterns,engagement_log} — all ownership-free (PersonalAnalyticsPolicy). PVA data flows from the
// extension sync, so a dashboard-only user sees honest cold-start states, never samples.
//
// Honest deferrals (no backend field): top-channel game names, feed emote column, exact sub start
// date + no-break days, the tenure "reliability" badge (supporter.tier is a supporter-category, not
// channel reputation — different semantics), export button. KPI «Стаж на Twitch» has no account-age
// field → relabelled to the real thing we have (max consecutive sub tenure). CSP-safe, no eval.
(function () {
  "use strict";

  var WINDOWS = { "Seg · Неделя": "7d", "Seg · Месяц": "30d", "Seg · Год": "365d" };
  var WINDOW_LABEL = { "7d": "неделю", "30d": "месяц", "365d": "год" };
  var DAY_ANCHOR = ["Вс", "Пн", "Вт", "Ср", "Чт", "Пт", "Сб"]; // JS getDay() order
  var DAY_ORDER = ["Пн", "Вт", "Ср", "Чт", "Пт", "Сб", "Вс"];
  var TYPE_RU = { sub: "Подписка", cheer: "Cheers", follow: "Фоллоу", hype_contribution: "Hype Train" };

  function q(root, name) { return (root || document).querySelector('[data-pencil-name="' + name + '"]'); }
  function qa(root, sel) { return Array.prototype.slice.call((root || document).querySelectorAll(sel)); }
  function qp(root, prefix) { return (root || document).querySelector('[data-pencil-name^="' + prefix + '"]'); }
  function setT(root, name, t) { var n = q(root, name); if (n != null && t != null) n.textContent = t; }
  function setP(root, prefix, t) { var n = qp(root, prefix); if (n != null && t != null) n.textContent = t; }
  function hide(el) { if (el) el.style.display = "none"; }
  function dim(el, title) { if (el) { el.style.opacity = "0.45"; el.style.pointerEvents = "none"; if (title) el.title = title; } }
  function initials(s) { s = (s || "").replace(/[^A-Za-zА-Яа-я0-9]/g, ""); return (s.slice(0, 1) || "?").toUpperCase(); }
  function hoursRu(sec) {
    if (sec == null) return "—";
    var h = sec / 3600;
    return (h >= 10 ? Math.round(h) : Math.round(h * 10) / 10).toString().replace(".", ",") + " ч";
  }
  function pctRu(x) { return x == null ? "—" : Math.round(x) + "%"; }

  var HEADERS = { Accept: "application/json", "Accept-Language": "ru" };
  function apiGet(p) {
    return fetch("/api/v1/me/analytics" + p, { headers: HEADERS, credentials: "same-origin" })
      .then(function (r) { return r.ok ? r.json() : Promise.reject(r.status); });
  }

  // ---- templates ----
  var T = {};
  function capture() {
    var tcRow = document.querySelector('[data-pencil-name^="TC Row · "]');
    var catRow = document.querySelector('[data-pencil-name^="Cat · "]');
    var feedRow = document.querySelector('[data-pencil-name^="Feed Row · "]');
    var insCard = document.querySelector('[data-pencil-name^="Ins · "]');
    if (tcRow) { T.tcRow = tcRow.cloneNode(true); T.tcParent = tcRow.parentNode; }
    if (catRow) { T.catRow = catRow.cloneNode(true); T.catParent = catRow.parentNode; }
    if (feedRow) { T.feedRow = feedRow.cloneNode(true); T.feedParent = feedRow.parentNode; }
    if (insCard) { T.insCard = insCard.cloneNode(true); T.insParent = insCard.parentNode; }
    return !!(T.tcRow && T.catRow && T.feedRow);
  }
  function removeAll(parent, prefix) {
    qa(parent, '[data-pencil-name^="' + prefix + '"]').forEach(function (n) { n.remove(); });
  }
  function emptyNote(parent, msg) {
    var d = document.createElement("div");
    d.setAttribute("data-pencil-name", "EmptyNote");
    d.style.cssText = "padding:18px 4px;color:#5E5E6B;font-family:Inter,system-ui,sans-serif;font-size:13px;";
    d.textContent = msg;
    parent.appendChild(d);
  }

  // ---- KPI row ----
  function kpi(cardName, value, delta) {
    var card = q(document, cardName);
    if (!card) return;
    setT(card, "KPI Value", value);
    var d = q(card, "KPI Delta");
    if (d) { if (delta == null) d.style.visibility = "hidden"; else { d.style.visibility = ""; d.textContent = delta; } }
  }

  // ---- overview (window-dependent) ----
  function renderOverview(windowKey) {
    apiGet("/overview?window=" + windowKey)
      .then(function (resp) {
        var d = (resp && resp.data) || {};
        var hero = d.hero || null;
        var label = WINDOW_LABEL[windowKey] || "неделю";

        // KPI: hours + delta
        var hoursCard = q(document, "KPI · Часы за неделю");
        if (hoursCard) setT(hoursCard, "KPI Label", "Часы за " + label);
        var deltaTxt = null;
        if (hero && hero.delta_seconds != null) {
          var prev = (hero.seconds || 0) - hero.delta_seconds; // previous equal window
          if (prev > 0) deltaTxt = (hero.delta_seconds >= 0 ? "+" : "−") + Math.abs(Math.round((hero.delta_seconds / prev) * 100)) + "%";
        }
        kpi("KPI · Часы за неделю", hero ? hoursRu(hero.seconds) : "0 ч", deltaTxt);

        // KPI: channels watched
        kpi("KPI · Каналов просмотрено", String((d.top_streamers || []).length), null);

        // hours chart — aggregate sparkline seconds by weekday
        renderBars(hero ? hero.sparkline || [] : [], hero ? hero.seconds : 0, label);

        // top channels
        renderTopChannels(d.top_streamers || [], hero ? hero.seconds : 0);

        // categories
        renderCategories(d.categories || []);

        // devices
        renderDevices(hero ? hero.devices || [] : []);
      })
      .catch(function () {});
  }

  function renderBars(sparkline, totalSeconds, label) {
    setT(document, "Chart Sub", "По дням недели · всего " + hoursRu(totalSeconds || 0));
    var byDay = {};
    DAY_ORDER.forEach(function (d) { byDay[d] = 0; });
    sparkline.forEach(function (p) {
      if (!p || !p.date) return;
      var day = DAY_ANCHOR[new Date(p.date).getDay()];
      if (day) byDay[day] += p.seconds || 0;
    });
    var max = Math.max.apply(null, DAY_ORDER.map(function (d) { return byDay[d]; }).concat([1]));
    var peakDay = null, peakVal = -1;
    DAY_ORDER.forEach(function (d) {
      var sec = byDay[d];
      if (sec > peakVal) { peakVal = sec; peakDay = d; }
      var bar = q(document, "Bar · " + d);
      if (bar) {
        bar.style.height = Math.max(6, Math.round((sec / max) * 96)) + "px";
        bar.style.opacity = sec === 0 ? "0.15" : "0.4";
      }
      setT(document, "Bar Val · " + d, (Math.round((sec / 3600) * 10) / 10).toString().replace(".", ","));
    });
    var peakBar = peakDay && q(document, "Bar · " + peakDay);
    if (peakBar && peakVal > 0) peakBar.style.opacity = "1";
    var peakNames = { "Пн": "понедельник", "Вт": "вторник", "Ср": "среда", "Чт": "четверг", "Пт": "пятница", "Сб": "суббота", "Вс": "воскресенье" };
    setP(document, "Peak T", peakVal > 0 ? "Пик: " + peakNames[peakDay] : "Нет данных");
  }

  function renderTopChannels(streamers, totalSeconds) {
    if (!T.tcRow || !T.tcParent) return;
    var footer = q(T.tcParent, "TC Footer");
    removeAll(T.tcParent, "TC Row · ");
    qa(T.tcParent, '[data-pencil-name="EmptyNote"]').forEach(function (n) { n.remove(); });
    if (!streamers.length) { emptyNote(T.tcParent, "Пока нет данных — смотрите стримы с расширением HimRate."); return; }
    streamers.slice(0, 5).forEach(function (s, i) {
      var row = T.tcRow.cloneNode(true);
      row.setAttribute("data-pencil-name", "TC Row · " + s.login);
      setP(row, "TC Rank", String(i + 1));
      setP(row, "TC Av T", initials(s.display_name || s.login));
      setP(row, "TC Name", s.display_name || s.login);
      setP(row, "TC Game", "twitch.tv/" + s.login); // game name isn't in the contract
      setP(row, "TC Hrs", hoursRu(s.seconds));
      setP(row, "TC Share", totalSeconds ? pctRu((s.seconds / totalSeconds) * 100) : "—");
      row.style.cursor = "pointer";
      row.addEventListener("click", function () { window.location.href = "/c/" + encodeURIComponent(s.login); });
      if (footer) T.tcParent.insertBefore(row, footer); else T.tcParent.appendChild(row);
    });
  }

  function renderCategories(categories) {
    if (!T.catRow || !T.catParent) return;
    removeAll(T.catParent, "Cat · ");
    qa(T.catParent, '[data-pencil-name="EmptyNote"]').forEach(function (n) { n.remove(); });
    if (!categories.length) { emptyNote(T.catParent, "Нет данных по категориям."); return; }
    categories.slice(0, 5).forEach(function (c) {
      var name = c.name && c.name !== "unknown" ? c.name : "Другое";
      var row = T.catRow.cloneNode(true);
      row.setAttribute("data-pencil-name", "Cat · " + name);
      setP(row, "Cat Name", name);
      setP(row, "Cat Pct", pctRu(c.pct));
      var fill = qp(row, "Cat Fill");
      if (fill) fill.style.width = Math.max(0, Math.min(100, c.pct || 0)) + "%";
      T.catParent.appendChild(row);
    });
  }

  function renderDevices(devices) {
    // Design legend: ПК / Телефон / ТВ-Консоль. Map real device names; hide legend rows with no data.
    var mapping = { "ПК": /desktop|pc|web/i, "Телефон": /mobile|phone|android|ios/i, "ТВ / Консоль": /tv|console|playstation|xbox/i };
    var total = devices.reduce(function (s, d) { return s + (d.seconds || 0); }, 0);
    if (!total) { dim(q(document, "Dev Bar")); }
    Object.keys(mapping).forEach(function (leg) {
      var sec = devices.filter(function (d) { return mapping[leg].test(d.name || ""); })
        .reduce(function (s, d) { return s + (d.seconds || 0); }, 0);
      setT(document, "Dev Leg Pct · " + leg, total ? pctRu((sec / total) * 100) : "—");
    });
  }

  // ---- communities (KPI messages) ----
  function renderCommunities(windowKey) {
    apiGet("/communities?window=" + windowKey)
      .then(function (resp) {
        var list = (resp && resp.data && resp.data.communities) || [];
        var msgs = list.reduce(function (s, c) { return s + (c.message_count || 0); }, 0);
        kpi("KPI · Сообщений в чате", String(msgs).replace(/\B(?=(\d{3})+(?!\d))/g, " "), null);
      })
      .catch(function () {});
  }

  // ---- supporter (KPI tenure + tenure card) ----
  function renderSupporter() {
    apiGet("/supporter")
      .then(function (resp) {
        var sup = ((resp && resp.data && resp.data.supporters) || [])
          .filter(function (s) { return s.tenure_months != null; })
          .sort(function (a, b) { return (b.tenure_months || 0) - (a.tenure_months || 0); })[0];

        // KPI: no Twitch account-age field exists → show the real thing we have (max sub tenure).
        var kpiCard = q(document, "KPI · Стаж на Twitch");
        if (kpiCard) setT(kpiCard, "KPI Label", "Макс. стаж подписки");
        kpi("KPI · Стаж на Twitch", sup ? tenureRu(sup.tenure_months) : "—", null);

        // tenure card
        var num = q(document, "Ten Num");
        if (!sup) {
          setT(document, "Ten Chan Name", "—");
          if (num) num.textContent = "0";
          emptyAfterTenure();
        } else {
          setT(document, "Ten Chan Name", sup.display_name || sup.login);
          setP(document, "Ten Av T", initials(sup.display_name || sup.login));
          if (num) num.textContent = String(sup.tenure_months);
        }
        // no fields for exact start date / no-break days / channel-reputation badge → hidden
        hide(q(document, "Ten St · С"));
        hide(q(document, "Ten St · Без пропуска"));
        hide(q(document, "Ten Badge Wrap"));
      })
      .catch(function () {});
  }
  function tenureRu(months) {
    if (months == null) return "—";
    var y = Math.floor(months / 12), m = months % 12;
    if (y > 0 && m > 0) return y + " л " + m + " мес";
    if (y > 0) return y + " л";
    return m + " мес";
  }
  function emptyAfterTenure() {
    var card = q(document, "Ten Head");
    if (card && card.parentNode) emptyNote(card.parentNode, "Подписок пока не обнаружено.");
  }

  // ---- reflection (recap + memory) ----
  function renderReflection() {
    apiGet("/reflection")
      .then(function (resp) {
        var refl = resp && resp.data && resp.data.reflection;
        if (!refl || !refl.narrative) { hide(q(document, "HL Recap")); hide(q(document, "HL Memory")); return; }
        setP(document, "Recap Body", refl.narrative);
        var moment = (refl.moments || [])[0];
        if (moment && (moment.description || moment.text)) {
          setP(document, "Mem Body", moment.description || moment.text);
          if (moment.occurred_at) setP(document, "Mem Date", String(moment.occurred_at).slice(0, 10));
        } else {
          hide(q(document, "HL Memory"));
        }
      })
      .catch(function () { hide(q(document, "HL Recap")); hide(q(document, "HL Memory")); });
  }

  // ---- patterns (insight cards) ----
  function renderPatterns() {
    apiGet("/patterns")
      .then(function (resp) {
        var patterns = (resp && resp.data && resp.data.patterns) || [];
        if (!T.insCard || !T.insParent) return;
        removeAll(T.insParent, "Ins · ");
        if (!patterns.length) { hide(q(document, "HL Insights")); return; }
        patterns.slice(0, 3).forEach(function (p) {
          var card = T.insCard.cloneNode(true);
          card.setAttribute("data-pencil-name", "Ins · " + (p.pattern_type || p.id));
          setP(card, "Ins Title", p.title || "");
          setP(card, "Ins T", p.body || "");
          T.insParent.appendChild(card);
        });
      })
      .catch(function () { hide(q(document, "HL Insights")); });
  }

  // ---- engagement log (feed) ----
  function renderFeed() {
    apiGet("/engagement_log")
      .then(function (resp) {
        var entries = (resp && resp.data && resp.data.entries) || [];
        if (!T.feedRow || !T.feedParent) return;
        removeAll(T.feedParent, "Feed Row · ");
        qa(T.feedParent, '[data-pencil-name="EmptyNote"]').forEach(function (n) { n.remove(); });
        setP(document, "Feed Count T", String(entries.length));
        hide(q(document, "Feed HCell · Эмоуты")); // no emote field in the contract
        if (!entries.length) { emptyNote(T.feedParent, "Событий пока нет — подписки, cheers и фоллоу появятся здесь."); return; }
        var link = q(T.feedParent, "Feed Link");
        entries.slice(0, 8).forEach(function (e) {
          var row = T.feedRow.cloneNode(true);
          var t = e.occurred_at ? String(e.occurred_at).slice(11, 16) : "—";
          row.setAttribute("data-pencil-name", "Feed Row · " + t + " " + e.login);
          setP(row, "FC Time", t);
          setP(row, "FC Av T", initials(e.display_name || e.login));
          setP(row, "FC Chan T", e.display_name || e.login);
          setP(row, "FC Msg T", TYPE_RU[e.type] || e.type || "—");
          var em = qp(row, "FC Em"); if (em) hide(em);
          if (link) T.feedParent.insertBefore(row, link); else T.feedParent.appendChild(row);
        });
      })
      .catch(function () {});
  }

  // ---- range toggle ----
  var activeWindow = "7d";
  function wireRange() {
    var segNames = Object.keys(WINDOWS);
    var activeSeg = q(document, "Seg · Неделя");
    var inactiveSeg = q(document, "Seg · Месяц");
    var activeClass = activeSeg && activeSeg.className;
    var inactiveClass = inactiveSeg && inactiveSeg.className;
    segNames.forEach(function (name) {
      var el = q(document, name);
      if (!el) return;
      el.style.cursor = "pointer";
      el.addEventListener("click", function () {
        activeWindow = WINDOWS[name];
        segNames.forEach(function (n2) {
          var el2 = q(document, n2);
          if (el2 && activeClass && inactiveClass) el2.className = n2 === name ? activeClass : inactiveClass;
        });
        renderOverview(activeWindow);
        renderCommunities(activeWindow);
      });
    });
    var allTime = q(document, "Seg · Всё время") || q(document, "Seg · всё время");
    if (allTime) dim(allTime, "Скоро");
  }

  // ---- boot ----
  function boot() {
    if (!capture()) return;
    dim(q(document, "Export Btn"), "Скоро");
    wireRange();
    renderOverview(activeWindow);
    renderCommunities(activeWindow);
    renderSupporter();
    renderReflection();
    renderPatterns();
    renderFeed();
  }

  fetch("/api/v1/lk/status", { headers: { Accept: "application/json" }, credentials: "same-origin" })
    .then(function (r) { return r.ok ? r.json() : {}; })
    .then(function (s) {
      if (!s || !s.authenticated) { window.location.href = "/login"; return; }
      boot();
    })
    .catch(function () { window.location.href = "/login"; });
})();
