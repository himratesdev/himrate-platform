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
  function disable(pencilName) {
    var n = el(pencilName);
    if (n) {
      n.style.opacity = "0.45";
      n.style.pointerEvents = "none";
      n.style.cursor = "default";
    }
  }

  var twitchBtn = el("OAuth Twitch");

  function renderLoggedIn(email) {
    setText("LC Title", "Вы вошли");
    setText("LC Sub", email ? "как " + email : "Аккаунт активен");
    setText("Tw T", "Выйти");
    if (twitchBtn) {
      var clone = twitchBtn.cloneNode(true); // drop any prior listener
      twitchBtn.parentNode.replaceChild(clone, twitchBtn);
      clone.style.cursor = "pointer";
      clone.addEventListener("click", go("/auth/web/logout"));
    }
  }

  function renderLoggedOut() {
    if (twitchBtn) {
      twitchBtn.style.cursor = "pointer";
      twitchBtn.addEventListener("click", go("/auth/web/twitch"));
    }
  }

  // Google + email are not wired yet — disable so they aren't dead-looking clickable controls.
  disable("OAuth Google");
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
