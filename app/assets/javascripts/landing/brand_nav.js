// Shared brand-dashboard chrome (sidebar + topbar) — makes the 4 brand pages navigate as one product.
// Included on every brand page (pages_controller sets @brand_dashboard). Wires the sidebar nav items
// that have a live route, route-based active highlight, and the topbar user + logout. Nav items whose
// page isn't built yet stay inert placeholders (no dead 404 links). CSP-safe external asset, no eval.
(function () {
  "use strict";

  // Sidebar nav anchor → live route. (Overlap has no sidebar entry in the design — reached from the
  // channel-comparison flow; it highlights "Сравнение".)
  var NAV = {
    "Nav · Главная": "/app/home",
    "Nav · Моя активность": "/app/activity",
    "Nav · Куда пойти": "/app/discover",
    "Nav · Watchlists": "/app/watchlists",
    "Nav · Лучшие моменты": "/app/moments",
    "Nav · Поиск стримеров": "/app/search",
    "Nav · Сравнение": "/app/compare",
    "Nav · Настройки": "/app/settings",
    "Nav · Мой канал": "/app/channel",
    "Nav · Рост": "/app/grow",
    "Nav · Мои соцсети": "/app/social",
  };
  var ACTIVE_BG = "#19152E";

  function q(name) { return document.querySelector('[data-pencil-name="' + name + '"]'); }

  var path = window.location.pathname;
  function isActive(route) {
    if (route === "/app/search") return path === "/app/search" || path.indexOf("/app/streamers") === 0;
    if (route === "/app/compare") return path === "/app/compare" || path === "/app/overlap";
    return path === route;
  }

  Object.keys(NAV).forEach(function (anchor) {
    var el = q(anchor);
    if (!el) return;
    var route = NAV[anchor];
    el.style.cursor = "pointer";
    el.addEventListener("click", function () { window.location.href = route; });
    el.style.backgroundColor = isActive(route) ? ACTIVE_BG : ""; // route-authoritative highlight
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
