// Dashboard login (screen 70). Wires the Twitch OAuth button to the web-login flow and reflects the
// session state. Twitch is fully functional; Google + email are disabled (follow-up: Google mirrors
// Twitch, email passwordless is blocked on an email provider). CSP-safe external asset, no eval.
(function () {
  "use strict";

  function el(pencilName) {
    return document.querySelector('[data-pencil-name="' + pencilName + '"]');
  }
  function setText(pencilName, text) {
    var n = el(pencilName);
    if (n != null && text != null) n.textContent = text;
  }
  function go(href) {
    return function (e) {
      if (e) e.preventDefault();
      window.location.href = href;
    };
  }
  function logout(e) {
    if (e) e.preventDefault();
    // DELETE (not a GET navigation) — no logout-CSRF; reload to the logged-out login page.
    fetch("/auth/web/logout", { method: "DELETE", credentials: "same-origin" }).then(function () {
      window.location.href = "/login";
    });
  }
  function disable(pencilName) {
    var n = el(pencilName);
    if (n) {
      n.style.opacity = "0.45";
      n.style.pointerEvents = "none";
      n.style.cursor = "default";
    }
  }

  var twitchBtn = el("OAuth Twitch");
  var googleBtn = el("OAuth Google");

  function renderLoggedIn(email) {
    setText("LC Title", "Вы вошли");
    setText("LC Sub", email ? "как " + email : "Аккаунт активен");
    setText("Tw T", "Выйти");
    if (twitchBtn) {
      var clone = twitchBtn.cloneNode(true); // drop any prior listener
      twitchBtn.parentNode.replaceChild(clone, twitchBtn);
      clone.style.cursor = "pointer";
      clone.addEventListener("click", logout);
    }
    // Signed in — the second provider button is noise; hide it.
    if (googleBtn) googleBtn.style.display = "none";
  }

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
      if (s && s.authenticated) renderLoggedIn(s.email);
      else renderLoggedOut();
    })
    .catch(function () {
      renderLoggedOut();
    });
})();
