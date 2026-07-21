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

  var DASHBOARD_HOME = "/app/home";
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
