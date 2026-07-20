// Brand dashboard audience overlap (screen 24) — wires REAL chat-audience overlap into the faithful
// Pencil export. Auth-gated: checks /api/v1/lk/status (httpOnly session cookie); unauthenticated →
// /login, non-brand (403) → in-page upgrade prompt. Compared channels come from the URL
// (?channels=a,b,c); data from the brand-gated GET /api/v1/brand/overlap (chat-presence graph).
//
// The overlap is a CHATTERS-only basis (audience_basis="chat_presence") — the design has no such
// disclaimer, so we inject one honestly. The design bakes a 3×3 matrix + 3 pairs + 4 segments as
// sample data; we render the real 2-4 channels by cloning the header/row/cell/bar/combo templates.
// CSP-safe: external asset, same-origin fetch, no eval.
(function () {
  "use strict";

  var API = "/api/v1/brand/overlap";
  var RISK_RU = { max_reach: "Макс. охват", optimal: "Оптимально", caution: "Осторожно" };
  var RISK_NOTE = { max_reach: "максимум уникального охвата", optimal: "минимальное пересечение", caution: "высокое пересечение" };
  var STRENGTH_RU = { weak: "мало дублей", medium: "умеренно дублей", strong: "много дублей" };
  // matrix cell colour by overlap strength (design palette).
  function cellColor(v) {
    if (v == null) return "#101014";
    if (v < 15) return "#171720";
    if (v <= 35) return "#1E1838";
    return "#7B5CFA";
  }

  // ---- dom helpers ----
  function q(root, name) { return (root || document).querySelector('[data-pencil-name="' + name + '"]'); }
  function setText(root, name, t) { var n = q(root, name); if (n != null && t != null) n.textContent = t; }
  function hide(el) { if (el) el.style.display = "none"; }
  function removeByPrefix(container, prefix) {
    if (!container) return;
    Array.prototype.slice.call(container.querySelectorAll('[data-pencil-name^="' + prefix + '"]'))
      .forEach(function (n) { n.remove(); });
  }
  function fmt(n) {
    if (n == null || isNaN(n)) return "—";
    return Math.round(n).toString().replace(/\B(?=(\d{3})+(?!\d))/g, " ");
  }
  function pct(v) { return v == null || isNaN(v) ? "—" : Math.round(v) + "%"; }
  function initials(s) { s = (s || "").replace(/[^A-Za-zА-Яа-я0-9]/g, ""); return (s.slice(0, 1) || "?").toUpperCase(); }

  function channelsParam() {
    return (new URLSearchParams(location.search).get("channels") || "")
      .split(",").map(function (s) { return s.trim(); }).filter(Boolean);
  }

  // ---- templates ----
  var T = {};
  function capture() {
    var ch = document.querySelector('[data-pencil-name^="CH · "]');
    var row = document.querySelector('[data-pencil-name^="Row · "]');
    var cell = q(document, "Cell 00");
    var pw = document.querySelector('[data-pencil-name^="PW · "]');
    var hb = document.querySelector('[data-pencil-name^="HB · "]');
    var combo = document.querySelector('[data-pencil-name^="Combo · "]');
    if (!ch || !row || !cell) return false;
    T.ch = ch.cloneNode(true);
    T.cell = cell.cloneNode(true);
    T.row = row.cloneNode(true);
    removeByPrefix(T.row, "Cell "); // empty row keeps the RL label, drops the 3 sample cells
    T.pw = pw && pw.cloneNode(true);
    T.hb = hb && hb.cloneNode(true);
    T.combo = combo && combo.cloneNode(true);
    T.pwParent = pw && pw.parentNode;
    T.hbParent = hb && hb.parentNode;
    T.comboParent = combo && combo.parentNode;
    return true;
  }

  // ---- render ----
  function render(d) {
    var channels = d.channels || [];
    renderHero(d, channels);
    renderKpi(d);
    renderMatrix(channels, d.matrix || {});
    renderPairwise(d.pairwise || []);
    renderComposition(d.composition || [], channels);
    renderRecommendations(d.recommendations || []);
    renderCallout(d.pairwise || []);
    injectBasisDisclaimer();
  }

  function renderHero(d, channels) {
    setText(document, "Sel T", channels.length + " " + plural(channels.length, "канал", "канала", "каналов") + ": " +
      channels.map(function (c) { return c.login; }).join(" · "));
    setText(document, "Big V", fmt(d.unique_reach));
    setText(document, "DL V", pct(d.unique_percentage));
    setText(document, "Hero Sub", "из " + fmt(d.total_reach) + " суммарно — " + fmt(d.total_reach - d.unique_reach) + " дублей");
  }

  function renderKpi(d) {
    var total = q(document, "KPI · Суммарно по каналам");
    if (total) setText(total, "K V", fmt(d.total_reach));
    var shared = (d.composition || []).filter(function (s) { return s.segment === "shared_2plus"; })[0];
    var inter = q(document, "KPI · Пересечение аудиторий");
    if (inter) setText(inter, "K V", fmt(shared ? shared.count : d.total_reach - d.unique_reach));
    // "Переплата за дубли" needs a CPM the engine doesn't have → hide honestly (no fabricated ₽).
    hide(q(document, "KPI · Переплата за дубли"));
  }

  function renderMatrix(channels, matrix) {
    var grid = q(document, "Grid");
    var colHead = q(grid, "Col Head");
    removeByPrefix(colHead, "CH · ");
    channels.forEach(function (c) {
      var ch = T.ch.cloneNode(true);
      ch.setAttribute("data-pencil-name", "CH · " + c.login);
      setText(ch, "AT", initials(c.display_name || c.login));
      setText(ch, "CHN", c.display_name || c.login);
      colHead.appendChild(ch);
    });
    removeByPrefix(grid, "Row · ");
    channels.forEach(function (rowC, i) {
      var row = T.row.cloneNode(true);
      row.setAttribute("data-pencil-name", "Row · " + rowC.login);
      setText(row, "AT", initials(rowC.display_name || rowC.login));
      setText(row, "RLN", rowC.display_name || rowC.login);
      channels.forEach(function (colC, j) {
        var cell = T.cell.cloneNode(true);
        cell.setAttribute("data-pencil-name", "Cell " + i + j);
        var diag = i === j;
        var v = diag ? null : (matrix[rowC.login] && matrix[rowC.login][colC.login]);
        setText(cell, "CT", diag ? "—" : pct(v));
        cell.style.backgroundColor = diag ? "#1C1C24" : cellColor(v);
        row.appendChild(cell);
      });
      grid.appendChild(row);
    });
  }

  function renderPairwise(pairwise) {
    if (!T.pw || !T.pwParent) return;
    removeByPrefix(T.pwParent, "PW · ");
    pairwise.forEach(function (p) {
      var el = T.pw.cloneNode(true);
      el.setAttribute("data-pencil-name", "PW · " + p.a + " × " + p.b);
      setText(el, "PL", p.a + " × " + p.b);
      setText(el, "PC", fmt(p.shared));
      setText(el, "PChT", pct(p.percent) + " · " + (STRENGTH_RU[p.strength] || ""));
      var fill = q(el, "PFill");
      if (fill) fill.style.width = Math.max(0, Math.min(100, p.percent || 0)) + "%";
      T.pwParent.appendChild(el);
    });
  }

  function renderComposition(composition, channels) {
    if (!T.hb || !T.hbParent) return;
    var loginByLower = {};
    channels.forEach(function (c) { loginByLower[c.login.toLowerCase()] = c.display_name || c.login; });
    removeByPrefix(T.hbParent, "HB · ");
    composition.forEach(function (s) {
      var el = T.hb.cloneNode(true);
      var label;
      if (s.segment === "shared_2plus") {
        label = "Смотрят 2+ канала";
      } else {
        var login = s.segment.replace(/^only_/, "");
        label = "Только " + (loginByLower[login.toLowerCase()] || login);
      }
      el.setAttribute("data-pencil-name", "HB · " + label);
      setText(el, "HB L", label);
      setText(el, "HB C", fmt(s.count));
      setText(el, "HB P", pct(s.percent));
      var fill = q(el, "HB Fill");
      if (fill) fill.style.width = Math.max(0, Math.min(100, s.percent || 0)) + "%";
      T.hbParent.appendChild(el);
    });
  }

  function renderRecommendations(recs) {
    if (!T.combo || !T.comboParent) return;
    removeByPrefix(T.comboParent, "Combo · ");
    recs.forEach(function (r) {
      var name = (r.combo || []).join(" + ");
      var el = T.combo.cloneNode(true);
      el.setAttribute("data-pencil-name", "Combo · " + name);
      setText(el, "CN", name);
      setText(el, "Stat V", pct(r.unique_percent));
      setText(el, "BdT", RISK_RU[r.risk] || "—");
      setText(el, "CNote", RISK_NOTE[r.risk] || "");
      T.comboParent.appendChild(el);
    });
  }

  function renderCallout(pairwise) {
    var block = q(document, "Callout · Не переплачивать");
    if (!block) return;
    var top = pairwise.slice().sort(function (a, b) { return (b.percent || 0) - (a.percent || 0); })[0];
    setText(block, "CO T", "Не переплачивайте за одних и тех же зрителей");
    if (top && top.percent != null) {
      setText(block, "CO S", "Каналы " + top.a + " и " + top.b + " делят " + pct(top.percent) +
        " чат-аудитории — комбинируйте каналы с меньшим пересечением ради охвата.");
    }
  }

  // Honest basis label (design omits it) — appended once under the hero.
  function injectBasisDisclaimer() {
    if (q(document, "BasisNote")) return;
    var hero = q(document, "Hero · Уникальный охват");
    if (!hero || !hero.parentNode) return;
    var note = document.createElement("div");
    note.setAttribute("data-pencil-name", "BasisNote");
    note.style.cssText = "width:100%;margin-top:8px;color:#5E5E6B;font-family:Inter,system-ui,sans-serif;font-size:12px;";
    note.textContent = "Данные о пересечении основаны на зрителях в чате (chat presence) — без учёта пассивных зрителей.";
    hero.parentNode.insertBefore(note, hero.nextSibling);
  }

  function plural(n, one, few, many) {
    n = Math.abs(n) % 100; var n1 = n % 10;
    if (n > 10 && n < 20) return many;
    if (n1 > 1 && n1 < 5) return few;
    if (n1 === 1) return one;
    return many;
  }

  // ---- states ----
  function fullScreenMsg(html) {
    var main = q(document, "Main Col") || document.body;
    Array.prototype.slice.call(main.querySelectorAll(
      '[data-pencil-name="Hero · Уникальный охват"], [data-pencil-name="KPI Strip"], [data-pencil-name="Analysis Row A"], [data-pencil-name="Analysis Row B"], [data-pencil-name="Callout · Не переплачивать"]'
    )).forEach(hide);
    var old = q(document, "MsgState");
    if (old) old.remove();
    var box = document.createElement("div");
    box.setAttribute("data-pencil-name", "MsgState");
    box.style.cssText = "width:100%;padding:64px 24px;text-align:center;color:#C7C7D1;font-family:Inter,system-ui,sans-serif;";
    box.innerHTML = html;
    main.appendChild(box);
  }
  function renderPrompt() {
    fullScreenMsg(
      '<div style="font-size:18px;font-weight:700;margin-bottom:8px;">Пересечение аудиторий</div>' +
      '<div style="font-size:14px;color:#9A9AA9;max-width:460px;margin:0 auto 20px;">Выберите 2–4 стримеров, чтобы увидеть, сколько у них общей аудитории и как не переплачивать за дубли.</div>' +
      '<a href="/app/search" style="display:inline-block;background:#7B5CFA;color:#fff;text-decoration:none;padding:11px 20px;border-radius:12px;font-weight:600;font-size:14px;">Найти стримеров</a>'
    );
  }
  function renderPaywall() {
    fullScreenMsg(
      '<div style="font-size:18px;font-weight:700;margin-bottom:8px;">Пересечение аудиторий — для бренд-аккаунтов</div>' +
      '<div style="font-size:14px;color:#9A9AA9;max-width:460px;margin:0 auto 20px;">Анализ пересечения аудиторий доступен на бизнес-тарифе.</div>' +
      '<a href="/brands" style="display:inline-block;background:#7B5CFA;color:#fff;text-decoration:none;padding:11px 20px;border-radius:12px;font-weight:600;font-size:14px;">Узнать о бренд-тарифах</a>'
    );
  }

  // ---- boot ----
  function load() {
    var channels = channelsParam();
    if (channels.length < 2) { renderPrompt(); return; }
    var u = new URLSearchParams(); u.set("channels", channels.join(","));
    fetch(API + "?" + u.toString(), {
      headers: { Accept: "application/json", "Accept-Language": "ru" }, credentials: "same-origin",
    })
      .then(function (r) {
        if (r.status === 403) { renderPaywall(); return null; }
        if (r.status === 404) { renderPrompt(); return null; }
        if (!r.ok) throw new Error("HTTP " + r.status);
        return r.json();
      })
      .then(function (d) { if (d) render(d); })
      .catch(function (e) {
        if (window.console) console.warn("[brand_overlap] load failed:", e);
        fullScreenMsg('<div style="font-size:15px;color:#9A9AA9;">Не удалось загрузить пересечение. Попробуйте позже.</div>');
      });
  }
  function boot() {
    if (!capture()) return;
    var rc = q(document, "Btn · Пересчитать");
    if (rc) { rc.style.cursor = "pointer"; rc.addEventListener("click", function () { location.href = "/app/search"; }); }
    load();
  }

  fetch("/api/v1/lk/status", { headers: { Accept: "application/json" }, credentials: "same-origin" })
    .then(function (r) { return r.ok ? r.json() : {}; })
    .then(function (s) {
      if (!s || !s.authenticated) { location.href = "/login"; return; }
      boot();
    })
    .catch(function () { location.href = "/login"; });
})();
