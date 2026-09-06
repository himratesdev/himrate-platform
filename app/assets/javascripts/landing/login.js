// Dashboard login (screen 70). Wires the Twitch + Google OAuth buttons to the web-login flow. A user
// who is ALREADY authenticated (or who just completed OAuth and got bounced here) is sent straight
// into the dashboard — the login page is never a resting place for a logged-in user. Email
// (passwordless) stays disabled until an email provider is wired. CSP-safe external asset, no eval.
(function () {
  "use strict";

  function el(pencilName) {
    return document.querySelector('[data-pencil-name="' + pencilName + '"]');
  }
  function go(href) {
    return function (e) {
      if (e) e.preventDefault();
      window.location.href = href;
    };
  }
  function disable(pencilName) {
    var n = el(pencilName);
    if (n) {
      n.style.opacity = "0.45";
      n.style.pointerEvents = "none";
      n.style.cursor = "default";
    }
  }

  // Host-mapping (2026-09): on the app host the canonical LK home is the short path.
  var DASHBOARD_HOME = location.hostname.indexOf("app.") === 0 ? "/home" : "/app/home";
  var twitchBtn = el("OAuth Twitch");
  var googleBtn = el("OAuth Google");

  function renderLoggedOut() {
    if (twitchBtn) {
      twitchBtn.style.cursor = "pointer";
      twitchBtn.addEventListener("click", go("/auth/web/twitch"));
    }
    if (googleBtn) {
      googleBtn.style.cursor = "pointer";
      googleBtn.addEventListener("click", go("/auth/web/google"));
    }
  }

  // Email (passwordless) is not wired yet — blocked on an email provider; disable so it isn't a
  // dead-looking clickable control. Twitch + Google are both live web-OAuth flows.
  disable("Email In");
  disable("Continue T");

  // Brand mark → back to marketing (escape hatch: a guest who reached /login and changed
  // their mind had no way back; SITE-AUDIT-2). Legal links are real <a href> in the view.
  // On the app host "/" is the LK home whose guest-gate bounces right back to /login — the
  // marketing site lives on the apex, so escape cross-host there.
  var MARKETING_HOME = location.hostname.indexOf("app.") === 0 ? "https://himrate.com/" : "/";
  ["L Logo", "L Wordmark"].forEach(function (name) {
    var n = el(name);
    if (n) {
      n.style.cursor = "pointer";
      n.addEventListener("click", go(MARKETING_HOME));
    }
  });

  // The promo card next to the form shows an invented channel with invented metrics — label it
  // as a sample so it can't be read as a real verdict about a real streamer.
  (function () {
    var row = el("LT Row1");
    if (!row || !row.parentNode) return;
    var cap = document.createElement("div");
    cap.textContent = "Пример карточки";
    cap.style.cssText = "font-size:11px;color:#5E5E6B;letter-spacing:.4px;margin-bottom:6px;";
    row.parentNode.insertBefore(cap, row);
  })();

  fetch("/api/v1/lk/status", { headers: { Accept: "application/json" }, credentials: "same-origin" })
    .then(function (r) {
      return r.ok ? r.json() : {};
    })
    .then(function (s) {
      // Already signed in (incl. the just-completed-OAuth bounce) → enter the dashboard, don't linger
      // on /login. replace() so Back doesn't return to the login page.
      if (s && s.authenticated) window.location.replace(DASHBOARD_HOME);
      else renderLoggedOut();
    })
    .catch(function () {
      renderLoggedOut();
    });
})();
