// Screen 40 «Подписка и биллинг» (P5). Faithful-host wiring: real plan data from
// GET /api/v1/subscriptions (promo grants — TASK-H8); billing chrome (checkout, cards, invoices,
// addons) honestly dimmed until the payment EPIC (TASK-042). Cancel = DELETE /api/v1/subscriptions/:id
// with an inline confirm plashka (no window.confirm). Listens for "hr:promo-redeemed" → reload.
(function () {
  "use strict";

  var HEADERS = { Accept: "application/json", "Accept-Language": "ru" };
  var TIER_LABEL = { free: "Бесплатный", premium: "Premium", business: "Business" };
  var INCLUDED = {
    free: ["Расширение — вся проверка каналов, без ограничений", "Watchlists и «Моя активность»", "1 бесплатный PDF-отчёт раз в 2 недели", "Публичные страницы каналов"],
    premium: ["Полный мониторинг канала в реальном времени", "Полная история и тренды канала", "PDF-отчёты по отслеживаемому каналу", "Compare между отслеживаемыми каналами"],
    business: ["Безлимитные каналы", "Compare между любыми каналами", "Audience Overlap", "Команда: 3 места (+$10/мес за место)"]
  };
  var activeSub = null;

  function q(root, name) { return root.querySelector('[data-pencil-name="' + name + '"]'); }
  function setT(name, text) { var el = q(document, name); if (el) el.textContent = text; }
  function dim(name, title) {
    var el = q(document, name);
    if (!el) return;
    el.style.opacity = "0.45"; el.style.pointerEvents = "none";
    if (title) el.title = title;
  }
  // Paired with dim(): render() runs again after «hr:promo-redeemed», so a control dimmed in the
  // no-subscription branch has to come back to life once a grant exists — without it the cancel
  // button stayed inert until F5 (CR P5 SF-1).
  function undim(name, title) {
    var el = q(document, name);
    if (!el) return;
    el.style.opacity = ""; el.style.pointerEvents = "";
    el.title = title || "";
  }

  function fmtDate(iso) {
    if (!iso) return null;
    return new Date(iso).toLocaleDateString("ru-RU", { day: "numeric", month: "long", year: "numeric" });
  }

  // The export paints the status pill green (dot + text + background) for its «Активна» sample.
  // Without a grant that green reads as an active subscription, so the whole pill goes neutral
  // (CR P5 Nit-4).
  function setStatusTone(active) {
    var dot = q(document, "Status Dot");
    var pill = q(document, "Status Pill");
    var text = q(document, "Status T");
    if (dot) dot.style.background = active ? "#25D9A4" : "#5E5E6B";
    if (pill) pill.style.background = active ? "#10271F" : "#1A1A20";
    if (text) text.style.color = active ? "#25D9A4" : "#9A9AA9";
  }

  function renderIncluded(tier) {
    var labels = INCLUDED[tier] || INCLUDED.free;
    var rows = document.querySelectorAll('[data-pencil-name^="Chk · "]');
    rows.forEach(function (row, i) {
      if (i >= labels.length) { row.style.display = "none"; return; }
      var t = row.querySelector('[data-pencil-name="Chk T"]') || row.lastElementChild;
      if (t) t.textContent = labels[i];
    });
  }

  function render(data) {
    var tier = data.tier || "free";
    var subs = (data.subscriptions || []).filter(function (s) { return s.is_active; });
    // Pick the grant that actually backs the displayed tier: the header reads data.tier (the
    // highest-ranked active grant server-side), so price/date/cancel must come from THAT row.
    // With a business + premium grant held at once, subs[0] (newest by started_at) showed the
    // premium term under a «Business» header and cancelled the wrong grant (CR P5 Nit-3).
    // Fallback to the newest row when nothing matches (tier from a non-subscription source).
    activeSub = subs.filter(function (s) { return s.tier === data.tier; })[0] || subs[0] || null;

    setT("Plan Name", TIER_LABEL[tier] || tier);
    setT("Plan Tier T", activeSub && activeSub.plan_type === "promo" ? "Промо-доступ" : (tier === "free" ? "Зритель" : "Подписка"));
    if (activeSub) {
      setT("Price", Number(activeSub.price) === 0 ? "$0" : "$" + activeSub.price);
      setT("Price Period", Number(activeSub.price) === 0 ? "промокод" : "/ мес");
      setT("Status T", "Активна");
      setStatusTone(true);
      setT("Renewal", activeSub.billing_period_end ? "Действует до " + fmtDate(activeSub.billing_period_end) : "Действует бессрочно");
      undim("Btn · Отменить");
    } else {
      setT("Price", "$0");
      setT("Price Period", "/ мес");
      setT("Status T", tier === "free" ? "Расширение — без ограничений" : "Нет активной подписки");
      setStatusTone(false);
      setT("Renewal", "—");
      dim("Btn · Отменить", "Нет активной подписки");
    }
    renderIncluded(tier);
  }

  function load() {
    return fetch("/api/v1/subscriptions", { headers: HEADERS, credentials: "same-origin" })
      .then(function (r) { return r.ok ? r.json() : null; })
      .then(function (j) { if (j && j.data) render(j.data); });
  }

  function wireCancel() {
    var btn = q(document, "Btn · Отменить");
    var confirmBox = document.getElementById("hr-cancel-confirm");
    var yes = document.getElementById("hr-cancel-yes");
    var no = document.getElementById("hr-cancel-no");
    var msg = document.getElementById("hr-sub-msg");
    if (!btn || !confirmBox || !yes || !no) return;
    btn.style.cursor = "pointer";
    btn.addEventListener("click", function () { if (activeSub) confirmBox.hidden = false; });
    no.addEventListener("click", function () { confirmBox.hidden = true; });
    yes.addEventListener("click", function () {
      if (!activeSub) return;
      yes.disabled = true;
      fetch("/api/v1/subscriptions/" + activeSub.id, {
        method: "DELETE", headers: HEADERS, credentials: "same-origin",
      })
        .then(function (r) { return r.json().then(function (j) { return { ok: r.ok, j: j }; }); })
        .then(function (res) {
          confirmBox.hidden = true;
          if (msg) {
            msg.textContent = res.ok ? "Подписка отменена." : "Не удалось отменить — попробуйте позже.";
            msg.style.color = res.ok ? "#25D9A4" : "#FF6B81";
            msg.hidden = false;
          }
          return load();
        })
        .catch(function () {})
        .then(function () { yes.disabled = false; });
    });
  }

  function wireLinks() {
    var cmp = q(document, "Btn · Сравнить тарифы");
    if (cmp) {
      cmp.style.cursor = "pointer";
      // Marketing pages live on the apex; LK runs on app.himrate.com (prod) or staging under
      // /app/*. Absolute apex URL ONLY from the prod app host (app.himrate.com/pricing would 301
      // to the apex anyway — this saves the hop); everywhere else a relative path keeps staging
      // and localhost inside their own host instead of bouncing QA into production (CR P5 SF-2,
      // mirrors the host-conditional convention in hr-shared.js / index.js).
      cmp.addEventListener("click", function () {
        window.location.href = location.hostname === "app.himrate.com" ? "https://himrate.com/pricing" : "/pricing";
      });
    }
  }

  function dimBillingChrome() {
    dim("Btn · Скачать счета", "Оплата подключается");
    dim("Btn · Сменить план", "Оплата подключается");
    dim("Addons Card", "Аддоны появятся после подключения оплаты");
    dim("Next Payment Card", "Оплата подключается");
    dim("Payment Method Card", "Оплата подключается");
    dim("Btn · Все операции", "Оплата подключается");
  }

  function boot() {
    dimBillingChrome();
    wireCancel();
    wireLinks();
    document.addEventListener("hr:promo-redeemed", function () { load(); });
    load();
  }

  fetch("/api/v1/lk/status", { headers: { Accept: "application/json" }, credentials: "same-origin" })
    .then(function (r) { return r.ok ? r.json() : {}; })
    .then(function (s) { if (!s || !s.authenticated) { window.location.href = "/login"; return; } boot(); })
    .catch(function () { window.location.href = "/login"; });
})();
