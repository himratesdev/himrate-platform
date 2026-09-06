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
    "Nav · Паутинка": "/graph",
    "Nav · Watchlists": "/watchlists",
    "Nav · Лучшие моменты": "/moments",
    "Nav · Поиск стримеров": "/search",
    "Nav · Поиск блогеров": "/creators",
    "Nav · Сравнение": "/compare",
    "Nav · Настройки": "/settings",
    "Nav · Мой канал": "/channel",
    "Nav · Рост": "/grow",
    "Nav · Мои соцсети": "/social",
    "Nav · Подключение": "/connect",
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

  // W5: «Паутинка» — новой страницы нет в Pencil-экспортах сайдбара; клонируем существующий
  // пункт «Куда пойти» и перетитловываем (тот же язык дизайна, ноль ручной разметки).
  (function () {
    var donor = q("Nav · Куда пойти");
    if (!donor || q("Nav · Паутинка")) return;
    var item = donor.cloneNode(true);
    item.setAttribute("data-pencil-name", "Nav · Паутинка");
    var label = item.querySelector('[data-pencil-name^="Nav Label"]');
    if (label) { label.setAttribute("data-pencil-name", "Nav Label · Паутинка"); label.textContent = "Паутинка"; }
    var icon = item.querySelector('[data-pencil-name^="Nav Icon"]');
    if (icon) icon.setAttribute("data-pencil-name", "Nav Icon · Паутинка");
    item.style.backgroundColor = "";
    donor.parentNode.insertBefore(item, donor.nextSibling);
  })();

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
    "Nav · Команда", "Nav · Подписка", "Nav · Шаблоны"];
  DEFERRED.forEach(function (name) {
    var el = q(name);
    if (!el) return;
    el.style.opacity = "0.4";
    el.style.cursor = "default";
    el.title = "Скоро";
  });

  // Account chrome: the sidebar `User` block (bottom-left) and the topbar avatar. The export ships a
  // design-sample persona («DH» / «Denis H.» / «Зритель · Стример · Бренд») — ALWAYS overwrite it with
  // the real session before anyone reads fabricated identity/roles. Guest → honest login CTA. Signed-in
  // click → small menu with «Выйти» (DELETE /auth/web/logout; login.js can't show logout — it bounces
  // authed users straight to /home, so this menu is the only logout entry point in the ЛК).
  var ROLE_RU = { viewer: "Зритель", streamer: "Стример", brand: "Бренд" };

  function setText(name, t) { var n = q(name); if (n) n.textContent = t; }

  function accountMenu(onLogout) {
    var menu = document.createElement("div");
    menu.setAttribute("data-pencil-name", "Account Menu");
    menu.style.cssText = "position:fixed;z-index:9999;background:#1C1C24;border:1px solid #25252F;" +
      "border-radius:10px;padding:6px;display:none;min-width:160px;box-shadow:0 8px 24px rgba(0,0,0,.5);";
    var out = document.createElement("div");
    out.textContent = "Выйти";
    out.style.cssText = "padding:8px 12px;border-radius:8px;cursor:pointer;color:#F4F4F7;font-size:14px;";
    out.addEventListener("mouseenter", function () { out.style.backgroundColor = "#25252F"; });
    out.addEventListener("mouseleave", function () { out.style.backgroundColor = ""; });
    out.addEventListener("click", onLogout);
    menu.appendChild(out);
    document.body.appendChild(menu);
    document.addEventListener("click", function (e) {
      if (!menu.contains(e.target)) menu.style.display = "none";
    }, true);
    return menu;
  }

  function doLogout() {
    fetch("/auth/web/logout", { method: "DELETE", credentials: "same-origin" })
      .catch(function () {})
      .then(function () { window.location.href = "/login"; });
  }

  function wireAccount(authed, email) {
    var targets = [q("User"), q("Account") || q("TB Avatar")].filter(Boolean);
    if (!targets.length) return;
    var menu = authed ? accountMenu(doLogout) : null;
    targets.forEach(function (el) {
      el.style.cursor = "pointer";
      el.title = authed ? (email || "Аккаунт") : "Войти";
      el.addEventListener("click", function (e) {
        if (!authed) { window.location.href = "/login"; return; }
        e.stopPropagation();
        var rect = el.getBoundingClientRect();
        menu.style.display = "block";
        // above the sidebar block, below the topbar avatar — keep it inside the viewport
        var top = rect.top > window.innerHeight / 2 ? rect.top - menu.offsetHeight - 8 : rect.bottom + 8;
        menu.style.top = top + "px";
        menu.style.left = Math.min(rect.left, window.innerWidth - 180) + "px";
      });
    });
  }

  fetch("/api/v1/lk/status", { headers: { Accept: "application/json" }, credentials: "same-origin" })
    .then(function (r) { return r.ok ? r.json() : {}; })
    .then(function (s) {
      var authed = !!(s && s.authenticated);
      if (authed) {
        var initial = (s.email || "?").slice(0, 1).toUpperCase();
        setText("TB Avatar T", initial);
        setText("Avatar T", initial);
        setText("User Name", (s.email || "").split("@")[0] || "Аккаунт");
        var roles = (s.roles || []).map(function (r) { return ROLE_RU[r] || null; }).filter(Boolean);
        setText("User Roles", roles.length ? roles.join(" · ") : "Зритель");
      } else {
        setText("TB Avatar T", "→");
        setText("Avatar T", "→");
        setText("User Name", "Гость");
        setText("User Roles", "Войти в аккаунт");
      }
      wireAccount(authed, s && s.email);
    })
    .catch(function () {
      // status unknown (network) — show neither the sample persona nor a false guest CTA
      setText("User Name", "—");
      setText("User Roles", "");
      setText("Avatar T", "·");
      setText("TB Avatar T", "·");
    });
})();
