// Shared «Промокод» card wiring (TASK-H8 → P5): used by /settings and /subscription. Self-inits
// when the card markup (#hr-promo-input) is present. On success dispatches "hr:promo-redeemed" so
// the hosting page can refresh its data (subscription.js reloads the plan card).
(function () {
  "use strict";

  var HEADERS = { Accept: "application/json", "Content-Type": "application/json", "Accept-Language": "ru" };

  function wirePromo() {
    var input = document.getElementById("hr-promo-input");
    var btn = document.getElementById("hr-promo-btn");
    var msg = document.getElementById("hr-promo-msg");
    if (!input || !btn || !msg) return;

    function show(text, ok) {
      msg.textContent = text;
      msg.style.color = ok ? "#25D9A4" : "#FF6B81";
      msg.hidden = false;
    }

    function redeem() {
      var code = (input.value || "").trim();
      if (!code) { show("Введите промокод", false); return; }
      btn.disabled = true; btn.style.opacity = "0.6";
      fetch("/api/v1/promocodes/redeem", {
        method: "POST", headers: HEADERS, credentials: "same-origin",
        body: JSON.stringify({ code: code }),
      })
        .then(function (r) { return r.json().then(function (j) { return { ok: r.ok, j: j }; }); })
        .then(function (res) {
          if (res.ok) {
            var d = res.j.data || {};
            show(d.message || "Готово! Промокод активирован.", true);
            input.value = "";
            document.dispatchEvent(new CustomEvent("hr:promo-redeemed", { detail: d }));
          } else {
            show((res.j.error && res.j.error.message) || "Не удалось активировать промокод", false);
          }
        })
        .catch(function () { show("Сеть недоступна — попробуйте ещё раз", false); })
        .then(function () { btn.disabled = false; btn.style.opacity = ""; });
    }

    btn.addEventListener("click", redeem);
    input.addEventListener("keydown", function (e) { if (e.key === "Enter") redeem(); });
  }

  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", wirePromo);
  else wirePromo();
})();
