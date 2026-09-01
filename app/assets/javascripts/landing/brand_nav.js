// Shared brand-dashboard chrome (sidebar + topbar) — makes the 4 brand pages navigate as one product.
// Included on every brand page (pages_controller sets @brand_dashboard). Wires the sidebar nav items
// that have a live route, route-based active highlight, and the topbar user + logout. Nav items whose
// page isn't built yet stay inert placeholders (no dead 404 links). CSP-safe external asset, no eval.
(function () {
  "use strict";

  // Host-mapping (2026-09): LK pages are served under TWO path schemes — canonical short paths on
  // app.himrate.com (/home) and the /app-prefixed scheme on staging/dev (/app/home). All internal
  // navigation therefore goes through hrAppPath(), which prepends the prefix the CURRENT page was
  // served under, so links stay same-scheme (no redirect hop) on both hosts.
  var APP_PREFIX = (window.location.pathname === "/app" || window.location.pathname.indexOf("/app/") === 0) ? "/app" : "";
  window.hrAppPath = function (p) { return APP_PREFIX + p; };

  // Sidebar nav anchor → live route (short form; hrAppPath adds the scheme prefix). (Overlap has no
  // sidebar entry in the design — reached from the channel-comparison flow; it highlights "Сравнение".)
  var NAV = {
    "Nav · Главная": "/home",
    "Nav · Моя активность": "/activity",
    "Nav · Куда пойти": "/discover",
    "Nav · Watchlists": "/watchlists",
    "Nav · Лучшие моменты": "/moments",
    "Nav · Поиск стримеров": "/search",
    "Nav · Поиск блогеров": "/creators",
    "Nav · Сравнение": "/compare",
    "Nav · Настройки": "/settings",
    "Nav · Мой канал": "/channel",
    "Nav · Рост": "/grow",
    "Nav · Мои соцсети": "/social",
  };
  var ACTIVE_BG = "#19152E";

  function q(name) { return document.querySelector('[data-pencil-name="' + name + '"]'); }

  // Compare against the DE-PREFIXED current path so highlight logic is scheme-agnostic.
  var path = window.location.pathname;
  if (APP_PREFIX && path.indexOf(APP_PREFIX) === 0) path = path.slice(APP_PREFIX.length) || "/";
  function isActive(route) {
    if (route === "/search") return path === "/search" || path.indexOf("/streamers") === 0;
    if (route === "/compare") return path === "/compare" || path === "/overlap";
    return path === route;
  }

  Object.keys(NAV).forEach(function (anchor) {
    var el = q(anchor);
    if (!el) return;
    var route = NAV[anchor];
    el.style.cursor = "pointer";
    el.addEventListener("click", function () { window.location.href = window.hrAppPath(route); });
    el.style.backgroundColor = isActive(route) ? ACTIVE_BG : ""; // route-authoritative highlight
  });

  // Sidebar items whose page isn't built yet: give them a visible "coming soon" state so they
  // don't read as active clickable rows with a silent dead click (SITE-AUDIT-2). "Поиск блогеров"
  // is deliberately NOT here — it has a live route (/app/creators) and is now wired above.
  var DEFERRED = ["Nav · Алерты", "Nav · Биржа", "Nav · Измерение", "Nav · Кампании",
    "Nav · Команда", "Nav · Подключение", "Nav · Подписка", "Nav · Шаблоны"];
  DEFERRED.forEach(function (name) {
    var el = q(name);
    if (!el) return;
    el.style.opacity = "0.4";
    el.style.cursor = "default";
    el.title = "Скоро";
  });

  // Topbar: show the signed-in user's initial and route the account control to /login (which shows the
  // session + logout via login.js). We intentionally do NOT wire an immediate logout on the avatar
  // (accidental-logout hazard), and NOT `TB Label` for the email — that anchor is reused by per-card
  // reputation badges elsewhere on the page.
  var acct = q("Account") || q("TB Avatar");
  if (acct) {
    acct.style.cursor = "pointer";
    acct.title = "Аккаунт";
    acct.addEventListener("click", function () { window.location.href = "/login"; });
  }

  fetch("/api/v1/lk/status", { headers: { Accept: "application/json" }, credentials: "same-origin" })
    .then(function (r) { return r.ok ? r.json() : {}; })
    .then(function (s) {
      if (s && s.authenticated && s.email) {
        var av = q("TB Avatar T");
        if (av) av.textContent = s.email.slice(0, 1).toUpperCase();
      }
    })
    .catch(function () {});
})();
