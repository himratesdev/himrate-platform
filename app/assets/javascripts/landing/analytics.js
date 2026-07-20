// Landing analytics — Yandex.Metrika + Google Analytics 4. Externalised (not inline)
// so the page stays CSP-clean; the layout only includes this on the canonical
// production host (himrate.com), so staging / localhost never pollute the stats.
// (TASK-060) IDs: Metrika 110889452 (webvisor + clickmap), GA4 G-ZS7MJT3QSP.
(function () {
  "use strict";

  // --- Yandex.Metrika (verbatim loader from the counter snippet) ---
  (function (m, e, t, r, i, k, a) {
    m[i] = m[i] || function () { (m[i].a = m[i].a || []).push(arguments); };
    m[i].l = 1 * new Date();
    for (var j = 0; j < e.scripts.length; j++) { if (e.scripts[j].src === r) { return; } }
    k = e.createElement(t); a = e.getElementsByTagName(t)[0];
    k.async = 1; k.src = r; a.parentNode.insertBefore(k, a);
  })(window, document, "script", "https://mc.yandex.ru/metrika/tag.js?id=110889452", "ym");

  ym(110889452, "init", {
    ssr: true, webvisor: true, clickmap: true, ecommerce: "dataLayer",
    accurateTrackBounce: true, trackLinks: true
  });

  // --- Google Analytics 4 ---
  var ga = document.createElement("script");
  ga.async = 1;
  ga.src = "https://www.googletagmanager.com/gtag/js?id=G-ZS7MJT3QSP";
  document.getElementsByTagName("script")[0].parentNode.insertBefore(ga, null);

  window.dataLayer = window.dataLayer || [];
  function gtag() { window.dataLayer.push(arguments); }
  gtag("js", new Date());
  gtag("config", "G-ZS7MJT3QSP");
})();
