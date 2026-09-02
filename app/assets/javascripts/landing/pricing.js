// Public pricing page (/pricing) — wires the faithful screen-41 host (canon = PRICING v4.2).
// Honest-data rules:
// - Checkout does not exist (TASK-042). Every plan CTA opens an inline «Оплата подключается»
//   capture that posts POST /api/v1/lk/notify {source: "pricing_interest", plan, email} — real
//   demand signal, no fake payment UI. A signed-in visitor (email from /api/v1/lk/status) is
//   subscribed with one click, no input shown.
// - The Free card CTA navigates to /viewers (the extension page) — nothing to buy.
// - Annual toggle: canon prices only (Premium $99/год, Business $999/год, −16%). Brand tiers
//   have no canonical annual price → cards untouched, a note appears instead. No invented numbers.
// CSP-safe external asset; textContent only (no innerHTML).
(function () {
  "use strict";

  function q(root, name) { return (root || document).querySelector('[data-pencil-name="' + name + '"]'); }
  function qa(root, sel) { return Array.prototype.slice.call((root || document).querySelectorAll(sel)); }

  var HEADERS = { Accept: "application/json", "Content-Type": "application/json", "Accept-Language": "ru" };

  var knownEmail = null;

  // ---- annual toggle (canon: Premium $99/год · Business $999/год · −16%) ----
  // Scope note: the toggle rewrites the two subscription CARDS only. The comparison matrix and the
  // «Годовая оплата» footnotes stay monthly on purpose — PRICING v4.2 defines no annual price for
  // the brand tiers, and re-deriving one in the matrix would invent a number.
  var yearly = false;
  var PRICES = {
    premium: { m: ["$9.99", "/мес за канал"], y: ["$99", "/год за канал · −16%"] },
    business: { m: ["$99", "/мес"], y: ["$999", "/год · −16%"] },
  };
  function applyPeriod() {
    Object.keys(PRICES).forEach(function (plan) {
      var card = document.querySelector('[data-plan="' + plan + '"]');
      if (!card) return;
      var v = yearly ? PRICES[plan].y : PRICES[plan].m;
      var price = q(card, "Price"); var period = q(card, "Period");
      if (price) price.textContent = v[0];
      if (period) period.textContent = v[1];
    });
    var mBtn = q(document, "Per · Месяц"); var yBtn = q(document, "Per · Год");
    if (mBtn && yBtn) {
      mBtn.style.background = yearly ? "transparent" : "#7B5CFA";
      yBtn.style.background = yearly ? "#7B5CFA" : "transparent";
      var mT = mBtn.querySelector("div"); var yT = yBtn.querySelector("div");
      if (mT) mT.style.color = yearly ? "#9A9AA9" : "#FFFFFF";
      if (yT) yT.style.color = yearly ? "#FFFFFF" : "#9A9AA9";
    }
    var note = document.getElementById("hr-annual-note");
    if (note) note.hidden = !yearly;
  }

  // ---- interest capture (no checkout yet — honest plashka) ----
  // The panel is MOVED next to the row that owns the clicked card: the page has two plan rows
  // («SPlans Row» = streamer/viewer, «Plans Row» = brand), and anchoring it once to the brand row
  // scrolled a Premium click past the fold into the wrong section (CR iter-1 SF-7). The annual note
  // keeps its brand-row anchor — it is about brand tiers.
  var plashka, plashkaMsg, plashkaInput, plashkaBtn, currentPlan = null;
  function rowOf(card) {
    var el = card;
    while (el && el !== document.body) {
      var name = el.getAttribute && el.getAttribute("data-pencil-name");
      if (name === "Plans Row" || name === "SPlans Row") return el;
      el = el.parentNode;
    }
    return null;
  }
  function moveTo(row) {
    if (!plashka || !row || !row.parentNode) return;
    if (plashka.previousSibling !== row) row.parentNode.insertBefore(plashka, row.nextSibling);
  }
  function buildPlashka() {
    var host = q(document, "SPlans Row") || q(document, "Plans Row");
    if (!host || !host.parentNode) return;
    plashka = document.createElement("div");
    plashka.id = "hr-plan-capture";
    plashka.hidden = true;
    plashka.style.cssText = "box-sizing:border-box;width:100%;display:flex;flex-direction:column;gap:10px;padding:16px 20px;background:#141419;border:1px solid #7B5CFA;border-radius:16px;font-family:Inter,system-ui,sans-serif;";
    var title = document.createElement("div");
    title.id = "hr-plan-capture-title";
    title.style.cssText = "color:#F4F4F7;font-size:14px;font-weight:700;";
    title.textContent = "Оплата подключается";
    var sub = document.createElement("div");
    sub.style.cssText = "color:#9A9AA9;font-size:13px;";
    sub.textContent = "Оставьте email — сообщим первыми, как только оформление откроется.";
    var row = document.createElement("div");
    row.style.cssText = "display:flex;gap:10px;align-items:center;";
    plashkaInput = document.createElement("input");
    plashkaInput.type = "email";
    plashkaInput.placeholder = "you@example.com";
    plashkaInput.autocomplete = "email";
    plashkaInput.style.cssText = "flex:1 1 0;height:38px;padding:0 12px;background:#0D0D12;color:#F4F4F7;font-size:13px;border:1px solid #25252F;border-radius:10px;outline:none;";
    plashkaBtn = document.createElement("button");
    plashkaBtn.type = "button";
    plashkaBtn.textContent = "Сообщить мне";
    plashkaBtn.style.cssText = "height:38px;padding:0 16px;background:#7B5CFA;color:#fff;font-size:13px;font-weight:600;border:none;border-radius:10px;cursor:pointer;";
    row.appendChild(plashkaInput); row.appendChild(plashkaBtn);
    plashkaMsg = document.createElement("div");
    plashkaMsg.hidden = true;
    plashkaMsg.style.cssText = "font-size:12px;";
    plashka.appendChild(title); plashka.appendChild(sub); plashka.appendChild(row); plashka.appendChild(plashkaMsg);
    // annual note (brand tiers have no canonical annual price)
    var note = document.createElement("div");
    note.id = "hr-annual-note";
    note.hidden = true;
    note.style.cssText = "color:#9A9AA9;font-size:12px;font-family:Inter,system-ui,sans-serif;";
    note.textContent = "Годовые цены брендовых тарифов — по договорённости (Talk to Sales).";
    host.parentNode.insertBefore(plashka, host.nextSibling);
    var brandRow = q(document, "Plans Row") || host;
    brandRow.parentNode.insertBefore(note, brandRow.nextSibling);
    plashkaBtn.addEventListener("click", submitInterest);
    plashkaInput.addEventListener("keydown", function (e) { if (e.key === "Enter") submitInterest(); });
  }
  function showMsg(text, ok) {
    plashkaMsg.textContent = text;
    plashkaMsg.style.color = ok ? "#25D9A4" : "#FF6B81";
    plashkaMsg.hidden = false;
  }
  function openCapture(plan, planTitle, card) {
    currentPlan = plan;
    if (!plashka) return;
    moveTo(card ? rowOf(card) : q(document, "Plans Row"));
    document.getElementById("hr-plan-capture-title").textContent =
      "Оплата подключается · план «" + planTitle + "»";
    plashkaMsg.hidden = true;
    plashka.hidden = false;
    // Scroll in BOTH paths: a signed-in visitor gets an instant «Готово», which is useless if it
    // renders off-screen (CR iter-1 SF-7).
    plashka.scrollIntoView({ behavior: "smooth", block: "center" });
    if (knownEmail) {
      plashkaInput.value = knownEmail;
      submitInterest();
    } else {
      plashkaInput.focus();
    }
  }
  function submitInterest() {
    var email = (plashkaInput.value || "").trim();
    if (!email) { showMsg("Введите email", false); return; }
    plashkaBtn.disabled = true; plashkaBtn.style.opacity = "0.6";
    fetch("/api/v1/lk/notify", {
      method: "POST", headers: HEADERS, credentials: "same-origin",
      body: JSON.stringify({ email: email, source: "pricing_interest", plan: currentPlan }),
    })
      .then(function (r) { return r.json().then(function (j) { return { ok: r.ok, j: j }; }); })
      .then(function (res) {
        if (res.ok) showMsg("Готово — напишем на " + email + ", как только оплата откроется.", true);
        else showMsg((res.j.error && res.j.error.code === "INVALID_EMAIL") ? "Похоже, это не email" : "Не получилось — попробуйте ещё раз", false);
      })
      .catch(function () { showMsg("Сеть недоступна — попробуйте ещё раз", false); })
      .then(function () { plashkaBtn.disabled = false; plashkaBtn.style.opacity = ""; });
  }

  // ---- CTA wiring ----
  var PLAN_TITLES = {
    free: "Free", premium: "Premium", business: "Business",
    starter: "Brand Starter", pro: "Brand Pro", enterprise: "Brand Enterprise", managed: "Managed",
  };
  function wireCtas() {
    qa(document, "[data-plan]").forEach(function (card) {
      var plan = card.getAttribute("data-plan");
      var cta = q(card, "CTA");
      if (!cta) return;
      cta.style.cursor = "pointer";
      cta.addEventListener("click", function () {
        if (plan === "free") { window.location.href = "/viewers"; return; }
        openCapture(plan, PLAN_TITLES[plan] || plan, card);
      });
    });
    var sales = q(document, "Btn · Talk to Sales");
    if (sales) {
      sales.style.cursor = "pointer";
      sales.addEventListener("click", function () {
        openCapture("managed", PLAN_TITLES.managed, q(document, "Plan · Managed"));
      });
    }
    var mBtn = q(document, "Per · Месяц"); var yBtn = q(document, "Per · Год");
    if (mBtn) { mBtn.style.cursor = "pointer"; mBtn.addEventListener("click", function () { yearly = false; applyPeriod(); }); }
    if (yBtn) { yBtn.style.cursor = "pointer"; yBtn.addEventListener("click", function () { yearly = true; applyPeriod(); }); }
  }

  // ---- ?plan= deep link (extension Settings anchors) ----
  function highlightFromQuery() {
    var m = /[?&]plan=([a-z]+)/.exec(window.location.search);
    if (!m) return;
    var card = document.querySelector('[data-plan="' + m[1] + '"]');
    if (!card) return;
    card.scrollIntoView({ behavior: "smooth", block: "center" });
    card.style.boxShadow = "0 0 0 2px #7B5CFA";
  }

  function boot() {
    buildPlashka();
    wireCtas();
    highlightFromQuery();
    // Signed-in visitor → one-click interest (email from the LK status probe; guests stay guests).
    fetch("/api/v1/lk/status", { headers: { Accept: "application/json" }, credentials: "same-origin" })
      .then(function (r) { return r.ok ? r.json() : null; })
      .then(function (s) { if (s && s.authenticated && s.email) knownEmail = s.email; })
      .catch(function () { /* guest */ });
  }

  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", boot);
  else boot();
})();
