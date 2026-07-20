// Viewer dashboard home (screen 01) — wires the viewer's REAL recent + live-from-watchlists channels
// into the faithful Pencil export. Auth-gated: /api/v1/lk/status (httpOnly cookie) → /login when
// unauthenticated. Data from GET /api/v1/me/home/recent_channels + /live_channels?source=watchlists
// (ownership-only, all-free per access-model v2). Each channel headline = TI/ERV (same as the public
// card). No mocks — the design's sample cards are cloned as templates and filled with real data.
// CSP-safe external asset, same-origin fetch, no eval.
(function () {
  "use strict";

  var LABEL_COLOR = { green: "#25D9A4", yellow: "#F5C451", red: "#F0616D", grey: "#9A9AA9", amber: "#F6A823" };

  function q(root, name) { return (root || document).querySelector('[data-pencil-name="' + name + '"]'); }
  // prefix match — Home card anchors are suffixed per channel (RName Buster) or per index (RRepT 1).
  function qp(root, prefix) { return (root || document).querySelector('[data-pencil-name^="' + prefix + '"]'); }
  function setP(root, prefix, text) { var n = qp(root, prefix); if (n != null && text != null) n.textContent = text; }
  function hideP(root, prefix) { var n = qp(root, prefix); if (n) n.style.display = "none"; }
  function fmt(n) {
    if (n == null || isNaN(n)) return "—";
    return Math.round(n).toString().replace(/\B(?=(\d{3})+(?!\d))/g, " ");
  }
  function initials(s) { s = (s || "").replace(/[^A-Za-zА-Яа-я0-9]/g, ""); return (s.slice(0, 2) || "?").toUpperCase(); }
  function color(ti) { return (ti && LABEL_COLOR[ti.label_color]) || "#9A9AA9"; }
  // % real: v2 rows carry authenticity, v1 rows erv_percent (same meaning).
  function pct(ti) { return ti == null ? null : (ti.authenticity != null ? ti.authenticity : ti.erv_percent); }
  // shown viewers = ccv, backed out from the stored erv_count / % real.
  function shown(ti) {
    var p = pct(ti);
    if (!ti || ti.erv_count == null || !p) return null;
    return Math.round(ti.erv_count / (p / 100));
  }

  function cardLink(login) { return "/c/" + encodeURIComponent(login); }

  // ---- recent (horizontal rows) ----
  function fillRecent(card, c) {
    var ti = c.trust_index || {};
    setP(card, "RAvT ", initials(c.display_name || c.login));
    setP(card, "RName ", c.display_name || c.login);
    setP(card, "RMeta ", c.is_live ? "В эфире сейчас" : "twitch.tv/" + c.login);
    setP(card, "RReal ", fmt(ti.erv_count));
    var real = qp(card, "RReal "); if (real) real.style.color = color(ti);
    setP(card, "RShown ", "/ " + fmt(shown(ti)));
    var fill = qp(card, "RBarFill "); if (fill) fill.style.width = (pct(ti) != null ? Math.max(0, Math.min(100, pct(ti))) : 0) + "%";
    if (ti.label) setP(card, "RRepT ", ti.label);
    var dot = qp(card, "RRepDot "); if (dot) dot.style.backgroundColor = color(ti);
    var repT = qp(card, "RRepT "); if (repT) repT.style.color = color(ti);
    hideP(card, "RAn "); // anomaly badge — not in the headline contract
    var open = qp(card, "ROpen ");
    if (open) { open.style.cursor = "pointer"; open.addEventListener("click", function (e) { e.stopPropagation(); window.location.href = cardLink(c.login); }); }
    card.style.cursor = "pointer";
    card.addEventListener("click", function () { window.location.href = cardLink(c.login); });
  }

  // ---- live (vertical cards) ----
  function fillLive(card, c) {
    var ti = c.trust_index || {};
    setP(card, "LAvT ", initials(c.display_name || c.login));
    setP(card, "LName ", c.display_name || c.login);
    if (!c.is_live) hideP(card, "LLive ");
    hideP(card, "LCat "); // category isn't in the headline contract
    setP(card, "LReal ", fmt(ti.erv_count));
    var real = qp(card, "LReal "); if (real) real.style.color = color(ti);
    setP(card, "LShown ", "из " + fmt(shown(ti)));
    var fill = qp(card, "LBarFill "); if (fill) fill.style.width = (pct(ti) != null ? Math.max(0, Math.min(100, pct(ti))) : 0) + "%";
    var dot = qp(card, "LRepDot "); if (dot) dot.style.backgroundColor = color(ti);
    card.style.cursor = "pointer";
    card.addEventListener("click", function () { window.location.href = cardLink(c.login); });
  }

  // Rebuild a section: clone `tplPrefix` first card per channel, replacing the sample cards.
  function renderSection(containerName, tplPrefix, channels, fill, emptyMsg) {
    var container = q(document, containerName);
    if (!container) return;
    var tpl = container.querySelector('[data-pencil-name^="' + tplPrefix + '"]');
    if (!tpl) return;
    var template = tpl.cloneNode(true);
    // remove the design's sample cards
    Array.prototype.slice.call(container.querySelectorAll('[data-pencil-name^="' + tplPrefix + '"]')).forEach(function (n) { n.remove(); });
    if (!channels.length) {
      var empty = document.createElement("div");
      empty.style.cssText = "padding:28px 8px;color:#5E5E6B;font-family:Inter,system-ui,sans-serif;font-size:14px;";
      empty.textContent = emptyMsg;
      container.appendChild(empty);
      return;
    }
    channels.forEach(function (c) {
      var card = template.cloneNode(true);
      card.setAttribute("data-pencil-name", tplPrefix + c.login);
      fill(card, c);
      container.appendChild(card);
    });
  }

  function load() {
    var opts = { headers: { Accept: "application/json", "Accept-Language": "ru" }, credentials: "same-origin" };
    fetch("/api/v1/me/home/recent_channels", opts)
      .then(function (r) { return r.ok ? r.json() : { data: [] }; })
      .then(function (d) {
        renderSection("Rec List", "RRow ", (d && d.data) || [], fillRecent, "Вы ещё не открывали каналы — найдите канал через поиск.");
      })
      .catch(function () {});
    fetch("/api/v1/me/home/live_channels?source=watchlists", opts)
      .then(function (r) { return r.ok ? r.json() : { data: [] }; })
      .then(function (d) {
        renderSection("Live Row", "LCard ", (d && d.data) || [], fillLive, "Нет каналов в эфире из ваших списков наблюдения.");
      })
      .catch(function () {});
  }

  fetch("/api/v1/lk/status", { headers: { Accept: "application/json" }, credentials: "same-origin" })
    .then(function (r) { return r.ok ? r.json() : {}; })
    .then(function (s) {
      if (!s || !s.authenticated) { window.location.href = "/login"; return; }
      load();
    })
    .catch(function () { window.location.href = "/login"; });
})();
