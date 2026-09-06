// Business-account application (screen 72) — wires the faithful export to the REAL singular
// /api/v1/business_profile resource. Auth-gated: /api/v1/lk/status → /login. Segment control =
// org_type, checkbox gates submit, «Сохранить черновик» → PUT (lenient), «Отправить на проверку»
// → POST submit (full validation) → stepper step 2 «Верификация» (honest: «до 1 рабочего дня»,
// PO reviews by hand). approved → step 3 + CTA to the brand search; rejected → review_note +
// editable form. Benefit rows for unbuilt engines (BAA / биржа / команда) are honestly dimmed
// «Скоро». CSP-safe external asset, no eval.
(function () {
  "use strict";

  var PURPLE = "#7B5CFA", DARK = "#1C1C24", TEXT_DIM = "#9A9AA9", TEXT_ON = "#FFFFFF";
  var APP_PREFIX = (window.location.pathname === "/app" || window.location.pathname.indexOf("/app/") === 0) ? "/app" : "";
  function appPath(p) { return APP_PREFIX + p; }

  function q(root, name) { return (root || document).querySelector('[data-pencil-name="' + name + '"]'); }
  function setT(root, name, t) { var n = q(root, name); if (n != null && t != null) n.textContent = t; }

  var HEADERS = { Accept: "application/json", "Accept-Language": "ru" };
  function api(method, path, params) {
    var opts = { method: method, headers: HEADERS, credentials: "same-origin" };
    if (params) {
      opts.headers = Object.assign({ "Content-Type": "application/json" }, HEADERS);
      opts.body = JSON.stringify(params);
    }
    return fetch(path, opts).then(function (r) {
      // guard: a non-JSON body (proxy 502 error page) must not blow up the chain — treat as empty
      return r.json().catch(function () { return {}; })
        .then(function (b) { return { ok: r.ok, status: r.status, body: b }; });
    });
  }

  var ORG_SEGMENTS = { "ООО": "ooo", "ИП": "ip", "Самозанятый": "self_employed" };
  var state = { org_type: "ooo", authority_confirmed: false, status: "none" };

  function field(name) { return document.querySelector('input[name="' + name + '"]'); }

  // ---- segment control ----
  function renderSegments() {
    Object.keys(ORG_SEGMENTS).forEach(function (label) {
      var seg = q(document, "BZ SegI " + label);
      var txt = q(document, "BZ SegT " + label);
      if (!seg) return;
      var active = ORG_SEGMENTS[label] === state.org_type;
      seg.style.backgroundColor = active ? PURPLE : "transparent";
      if (txt) txt.style.color = active ? TEXT_ON : TEXT_DIM;
    });
  }

  // ---- checkbox ----
  function renderCheckbox() {
    var cb = q(document, "BZ CB");
    var icon = q(document, "BZ CB I");
    if (!cb) return;
    cb.style.backgroundColor = state.authority_confirmed ? PURPLE : DARK;
    cb.style.border = state.authority_confirmed ? "0" : "1px solid #25252F";
    if (icon) icon.style.visibility = state.authority_confirmed ? "visible" : "hidden";
    renderSubmit();
  }

  function renderSubmit() {
    var btn = q(document, "BZ Submit");
    if (!btn) return;
    var enabled = state.authority_confirmed && !isLocked();
    btn.style.opacity = enabled ? "1" : "0.4";
    btn.style.cursor = enabled ? "pointer" : "default";
  }

  function isLocked() { return state.status === "pending" || state.status === "approved"; }

  // ---- stepper ----
  function renderStepper() {
    var step = state.status === "approved" ? 3 : (state.status === "pending" ? 2 : 1);
    for (var i = 1; i <= 3; i++) {
      var num = q(document, "BZ SNum " + i);
      var numT = q(document, "BZ SNum T " + i);
      var lbl = q(document, "BZ SLbl " + i);
      var on = i <= step;
      if (num) { num.style.backgroundColor = on ? PURPLE : DARK; num.style.borderColor = on ? PURPLE : "#25252F"; }
      if (numT) numT.style.color = on ? TEXT_ON : "#5E5E6B";
      if (lbl) { lbl.style.color = on ? "#F4F4F7" : "#5E5E6B"; }
    }
  }

  function renderStatusNote(text, color) {
    var foot = q(document, "BZ FNote");
    if (foot) { foot.textContent = text; foot.style.color = color || "#5E5E6B"; foot.style.whiteSpace = "normal"; }
  }

  function renderState() {
    renderSegments();
    renderCheckbox();
    renderStepper();

    ["company_name", "inn", "website", "sphere"].forEach(function (n) {
      var el = field(n); if (el) el.disabled = isLocked();
    });
    var seg = q(document, "BZ Seg");
    if (seg) seg.style.pointerEvents = isLocked() ? "none" : "";

    if (state.status === "pending") {
      renderStatusNote("Заявка на проверке — до 1 рабочего дня. Мы напишем на почту.", "#F6A823");
      setT(document, "BZ Submit T", "Отправлено на проверку");
      var d = q(document, "BZ Draft"); if (d) d.style.display = "none";
    } else if (state.status === "approved") {
      renderStatusNote("Компания подтверждена — инструменты бренда открыты.", "#25D9A4");
      setT(document, "BZ Submit T", "Перейти к поиску стримеров");
      var btn = q(document, "BZ Submit");
      if (btn) {
        btn.style.opacity = "1"; btn.style.cursor = "pointer";
        btn.addEventListener("click", function () { window.location.href = appPath("/search"); });
      }
      var dr = q(document, "BZ Draft"); if (dr) dr.style.display = "none";
    } else if (state.status === "rejected") {
      renderStatusNote("Заявка отклонена" + (state.review_note ? ": " + state.review_note : "") +
        " — исправьте данные и отправьте снова.", "#FB4E55");
    }
  }

  function collectParams() {
    return {
      org_type: state.org_type,
      company_name: (field("company_name") || {}).value || "",
      inn: (field("inn") || {}).value || "",
      website: (field("website") || {}).value || "",
      sphere: (field("sphere") || {}).value || "",
      authority_confirmed: state.authority_confirmed
    };
  }

  function prefill(data) {
    state.status = data.status || "none";
    state.org_type = data.org_type || "ooo";
    state.authority_confirmed = !!data.authority_confirmed;
    state.review_note = data.review_note;
    ["company_name", "inn", "website", "sphere"].forEach(function (n) {
      var el = field(n); if (el && data[n]) el.value = data[n];
    });
    renderState();
  }

  // ---- honest deferrals: benefits whose engines aren't built yet ----
  function deferBenefits() {
    ["BZ Ben target", "BZ Ben store", "BZ Ben users"].forEach(function (n) {
      var row = q(document, n);
      if (row) { row.style.opacity = "0.4"; row.title = "Скоро"; }
    });
  }

  function wire() {
    Object.keys(ORG_SEGMENTS).forEach(function (label) {
      var seg = q(document, "BZ SegI " + label);
      if (!seg) return;
      seg.style.cursor = "pointer";
      seg.addEventListener("click", function () {
        state.org_type = ORG_SEGMENTS[label];
        renderSegments();
      });
    });

    var check = q(document, "BZ Check");
    if (check) {
      check.style.cursor = "pointer";
      check.addEventListener("click", function () {
        if (isLocked()) return;
        state.authority_confirmed = !state.authority_confirmed;
        renderCheckbox();
      });
    }

    var draft = q(document, "BZ Draft");
    if (draft) {
      draft.style.cursor = "pointer";
      draft.addEventListener("click", function () {
        if (isLocked()) return;
        api("PUT", "/api/v1/business_profile", collectParams()).then(function (r) {
          if (r.ok) {
            renderStatusNote("Черновик сохранён", "#25D9A4");
            state.status = (r.body.data && r.body.data.status) || "draft";
          } else {
            renderStatusNote((r.body && r.body.message) || "Не удалось сохранить", "#FB4E55");
          }
        });
      });
    }

    var submit = q(document, "BZ Submit");
    if (submit) {
      submit.addEventListener("click", function () {
        if (!state.authority_confirmed || isLocked()) return;
        api("POST", "/api/v1/business_profile/submit", collectParams()).then(function (r) {
          if (r.ok) {
            prefill(r.body.data || {});
          } else {
            renderStatusNote((r.body && r.body.message) || "Проверьте поля формы", "#FB4E55");
          }
        });
      });
    }

    var back = q(document, "BZ Back");
    if (back) {
      back.style.cursor = "pointer";
      back.addEventListener("click", function () { window.location.href = appPath("/home"); });
    }
  }

  // Auth gate: ONLY the lk/status probe (and its own network failure) decides the /login redirect.
  // Profile-load / wiring errors show an honest note on the form instead of bouncing to /login.
  api("GET", "/api/v1/lk/status").then(
    function (r) {
      if (!r.ok || !r.body || !r.body.authenticated) { window.location.href = "/login"; return; }
      try {
        deferBenefits();
        wire();
      } catch (e) {
        renderStatusNote("Что-то пошло не так — обновите страницу.", "#FB4E55");
        return;
      }
      api("GET", "/api/v1/business_profile").then(function (p) {
        prefill((p.ok && p.body.data) || {});
      }).catch(function () {
        renderStatusNote("Не удалось загрузить данные заявки — обновите страницу.", "#FB4E55");
      });
    },
    function () { window.location.href = "/login"; }
  );
})();
