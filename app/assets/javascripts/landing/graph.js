// W5 «Паутинка» — interactive audience-overlap force graph. REAL data only:
// GET /api/v1/graph/audience (registered-gated; 401 → login). Self-contained canvas
// force simulation — CSP allows no CDN/libraries. Hover = neighbor highlight + tooltip,
// click = ego mode (?focus=login), drag = pan, wheel = zoom, «Карточка →» via dblclick.
(function () {
  "use strict";

  var BAND_HEX = { green: "#25D9A4", yellow: "#F5C451", red: "#F0616D", grey: "#9A9AA9", amber: "#F6A823" };
  var canvas = document.getElementById("hr-graph-canvas");
  var note = document.getElementById("hr-graph-note");
  var tip = document.getElementById("hr-graph-tip");
  var sub = document.getElementById("hr-graph-sub");
  var focusInput = document.getElementById("hr-graph-focus");
  var resetBtn = document.getElementById("hr-graph-reset");
  if (!canvas) return;
  var ctx = canvas.getContext("2d");

  var nodes = [], edges = [], byId = {};
  var view = { x: 0, y: 0, k: 1 };
  var hover = null, dragging = false, dragStart = null, raf = null, alpha = 0;
  var isBrand = false; // from lk/status roles — gates the brand-value insight blocks
  var APP_PREFIX = (window.location.pathname === "/app" || window.location.pathname.indexOf("/app/") === 0) ? "/app" : "";

  // ---- client-side filters over the loaded payload ----
  var raw = { nodes: [], edges: [], focus: null };
  var filters = { bands: null, minAud: 0, minShare: 0 }; // bands=null → all verdicts
  var selected = {}; // login → node (shift+click set, feeds the exact /overlap deep-link)
  var searchTerm = "";

  function applyFilters() {
    var ns = raw.nodes.filter(function (n) {
      if (raw.focus && n.login === raw.focus) return true; // never filter the ego out
      if (filters.bands && !filters.bands[n.band || "grey"]) return false;
      return (n.audience || 0) >= filters.minAud;
    });
    var present = {};
    ns.forEach(function (n) { present[n.id] = true; });
    var es = raw.edges.filter(function (e) {
      return present[e.a] && present[e.b] && (e.share || 0) >= filters.minShare;
    });
    // Full mode: drop nodes left with no ties — they'd float as unreadable dust. Ego keeps all.
    if (!raw.focus) {
      var deg = {};
      es.forEach(function (e) { deg[e.a] = 1; deg[e.b] = 1; });
      ns = ns.filter(function (n) { return deg[n.id]; });
    }
    start(ns, es, raw.focus);
    markSearch();
    buildInsights(ns, es, raw.focus);
    if (sub) {
      sub.textContent = (raw.focus ? "Паутинка канала " + raw.focus + " · " : "") +
        ns.length + " каналов · " + es.length + " связей · основа: активность в чатах" +
        (ns.length < raw.nodes.length || es.length < raw.edges.length ? " · фильтры активны" : "");
    }
    renderSelChips();
  }

  // ---- interpretation panel (the paid-value layer over the picture) ----
  var insightPanel = document.getElementById("hr-insight-panel");
  var insightBody = document.getElementById("hr-insight-body");
  var insightToggle = document.getElementById("hr-insight-toggle");
  if (insightToggle) insightToggle.addEventListener("click", function () {
    if (insightPanel) insightPanel.hidden = !insightPanel.hidden;
  });

  function fmtN(n) { return (n == null ? "—" : Math.round(n).toLocaleString("ru-RU")); }
  function pct(x) { return Math.round(x * 100) + "%"; }

  function el(tag, css, text) {
    var d = document.createElement(tag);
    if (css) d.style.cssText = css;
    if (text != null) d.textContent = text;
    return d;
  }
  function section(title, hint) {
    var s = el("div", "display:flex;flex-direction:column;gap:6px;padding:10px 12px;background:#141419;border:1px solid #25252F;border-radius:12px;");
    s.appendChild(el("div", "font-size:12.5px;font-weight:700;color:#F4F4F7;", title));
    if (hint) s.appendChild(el("div", "font-size:10.5px;color:#5E5E6B;", hint));
    return s;
  }
  function line(s, text, tone, login) {
    var colors = { ok: "#C7C7D1", warn: "#F6A823", dim: "#8E8A9A", strong: "#F4F4F7" };
    var d = el("div", "font-size:12px;line-height:1.45;color:" + (colors[tone] || colors.ok) + ";", text);
    if (login) { // any named channel row acts as a drill-down into that channel's ego web
      d.style.cursor = "pointer";
      d.title = "Открыть паутинку " + login;
      d.addEventListener("click", function () { if (focusInput) focusInput.value = login; load(login); });
    }
    s.appendChild(d);
  }
  function focusLink(s, login, label) {
    var a = el("a", "font-size:12px;color:#A78BFA;cursor:pointer;text-decoration:none;", label);
    a.addEventListener("click", function () { if (focusInput) focusInput.value = login; load(login); });
    s.appendChild(a);
  }
  function brandGate(s, teaserCount, totalCount, what) {
    if (isBrand) return;
    if (totalCount > teaserCount) line(s, "… ещё " + (totalCount - teaserCount) + " " + what + " — в бизнес-тарифе", "dim");
    var a = el("a", "display:inline-block;margin-top:4px;font-size:12px;font-weight:600;color:#C9B8FF;text-decoration:none;cursor:pointer;", "Создать бизнес-учётку →");
    a.href = APP_PREFIX + "/business/new";
    s.appendChild(a);
  }

  // ---- filter toolbar (built into #hr-graph-filters) ----
  var BAND_LABEL = { green: "реальная", amber: "amber", yellow: "аномалия", red: "значительная", grey: "мало данных" };
  function buildToolbar() {
    var bar = document.getElementById("hr-graph-filters");
    if (!bar) return;
    bar.textContent = "";
    bar.appendChild(el("span", "font-size:11.5px;color:#5E5E6B;", "Фильтры:"));

    // verdict chips (multi-toggle; all on = no filter)
    Object.keys(BAND_LABEL).forEach(function (band) {
      var on = !filters.bands || filters.bands[band];
      var chip = el("button", "display:flex;align-items:center;gap:6px;padding:6px 11px;border-radius:999px;" +
        "border:1px solid " + (on ? "#3A2F63" : "#25252F") + ";background:" + (on ? "#19152E" : "#141419") +
        ";color:" + (on ? "#F4F4F7" : "#5E5E6B") + ";font-size:11.5px;cursor:pointer;font-family:inherit;");
      chip.type = "button";
      var dot = el("span", "width:8px;height:8px;border-radius:99px;background:" + (BAND_HEX[band] || "#9A9AA9") +
        ";opacity:" + (on ? "1" : ".35") + ";");
      chip.appendChild(dot);
      chip.appendChild(document.createTextNode(BAND_LABEL[band]));
      chip.addEventListener("click", function () {
        if (!filters.bands) { // first narrowing click: keep only this band
          filters.bands = {};
          Object.keys(BAND_LABEL).forEach(function (b) { filters.bands[b] = (b === band); });
        } else {
          filters.bands[band] = !filters.bands[band];
          var anyOff = Object.keys(BAND_LABEL).some(function (b) { return !filters.bands[b]; });
          if (!anyOff) filters.bands = null;
          else if (!Object.keys(BAND_LABEL).some(function (b) { return filters.bands[b]; })) filters.bands = null; // none left → reset
        }
        buildToolbar();
        applyFilters();
      });
      bar.appendChild(chip);
    });

    function select(labelText, options, current, onChange) {
      var wrap = el("label", "display:flex;align-items:center;gap:6px;font-size:11.5px;color:#8E8A9A;");
      wrap.appendChild(document.createTextNode(labelText));
      var sel = document.createElement("select");
      sel.style.cssText = "background:#141419;color:#F4F4F7;border:1px solid #25252F;border-radius:8px;" +
        "padding:6px 8px;font-size:11.5px;font-family:inherit;outline:none;cursor:pointer;";
      options.forEach(function (o) {
        var opt = document.createElement("option");
        opt.value = o[0]; opt.textContent = o[1];
        if (String(o[0]) === String(current)) opt.selected = true;
        sel.appendChild(opt);
      });
      sel.addEventListener("change", function () { onChange(sel.value); applyFilters(); });
      wrap.appendChild(sel);
      return wrap;
    }
    bar.appendChild(select("аудитория ≥", [[0, "любая"], [100, "100"], [500, "500"], [1000, "1 000"], [5000, "5 000"]],
      filters.minAud, function (v) { filters.minAud = parseInt(v, 10) || 0; }));
    bar.appendChild(select("доля общих ≥", [[0, "любая"], [0.05, "5%"], [0.1, "10%"], [0.2, "20%"], [0.4, "40%"]],
      filters.minShare, function (v) { filters.minShare = parseFloat(v) || 0; }));

    var reset = el("button", "padding:6px 11px;border-radius:8px;border:1px solid #25252F;background:transparent;" +
      "color:#8E8A9A;font-size:11.5px;cursor:pointer;font-family:inherit;", "сбросить");
    reset.type = "button";
    reset.addEventListener("click", function () {
      filters = { bands: null, minAud: 0, minShare: 0 };
      buildToolbar();
      applyFilters();
    });
    bar.appendChild(reset);
  }

  // ---- search highlight (find on the FULL graph without switching to ego) ----
  var searchInput = document.getElementById("hr-graph-search");
  function markSearch() {
    var hit = null;
    nodes.forEach(function (n) {
      n.hl = !!(searchTerm && n.login.indexOf(searchTerm) !== -1);
      if (n.hl && !hit) hit = n;
    });
    if (hit) { // center the first match
      var W = canvas.width / devicePixelRatio, H = canvas.height / devicePixelRatio;
      view.x = W / 2 - hit.x * view.k;
      view.y = H / 2 - hit.y * view.k;
    }
    draw();
  }
  if (searchInput) searchInput.addEventListener("input", function () {
    searchTerm = searchInput.value.trim().toLowerCase();
    markSearch();
  });

  // ---- shift+click media-set selection → exact /overlap deep-link (max 4 channels) ----
  function renderSelChips() {
    var box = document.getElementById("hr-graph-selchips");
    if (!box) return;
    box.textContent = "";
    var logins = Object.keys(selected);
    if (!logins.length) return;
    box.appendChild(el("span", "font-size:11px;color:#8E8A9A;", "Набор для сравнения:"));
    logins.forEach(function (login) {
      var chip = el("button", "display:flex;align-items:center;gap:5px;padding:4px 9px;border-radius:999px;" +
        "border:1px solid #3A2F63;background:#19152E;color:#E9E4FF;font-size:11px;cursor:pointer;font-family:inherit;",
        login + " ×");
      chip.type = "button";
      chip.title = "Убрать из набора";
      chip.addEventListener("click", function () { delete selected[login]; renderSelChips(); draw(); });
      box.appendChild(chip);
    });
    if (logins.length >= 2 && logins.length <= 4) {
      var a = el("a", "padding:5px 11px;border-radius:999px;background:#7B5CFA;color:#fff;font-size:11px;" +
        "font-weight:600;text-decoration:none;cursor:pointer;", "Точный охват набора →");
      a.href = APP_PREFIX + "/overlap?channels=" + logins.join(",");
      a.title = "Точный пересчёт уникального охвата этих каналов (инструмент бренда)";
      box.appendChild(a);
    } else if (logins.length > 4) {
      box.appendChild(el("span", "font-size:11px;color:#F6A823;", "максимум 4 канала"));
    } else {
      box.appendChild(el("span", "font-size:11px;color:#5E5E6B;", "добавьте ещё канал (shift+клик)"));
    }
  }

  // Lightweight communities: keep each node's top-3 strongest ties (by overlap share) and take
  // connected components — dense-graph-safe (full components on 3000 edges would merge everything).
  function communities(ns, es) {
    var top = {};
    es.forEach(function (e) {
      if (e.share == null) return;
      [e.a, e.b].forEach(function (id) {
        (top[id] = top[id] || []).push(e);
      });
    });
    var kept = {};
    Object.keys(top).forEach(function (id) {
      top[id].sort(function (x, y) { return (y.share || 0) - (x.share || 0); });
      top[id].slice(0, 3).forEach(function (e) { kept[e.a + ":" + e.b] = e; });
    });
    var parent = {};
    function find(x) { while (parent[x] !== x) { parent[x] = parent[parent[x]]; x = parent[x]; } return x; }
    ns.forEach(function (n) { parent[n.id] = n.id; });
    Object.keys(kept).forEach(function (k) {
      var e = kept[k];
      if (parent[e.a] === undefined || parent[e.b] === undefined) return;
      var ra = find(e.a), rb = find(e.b);
      if (ra !== rb) parent[ra] = rb;
    });
    var comps = {};
    ns.forEach(function (n) { var r = find(n.id); (comps[r] = comps[r] || []).push(n); });
    var list = Object.keys(comps).map(function (r) { return comps[r]; }).filter(function (c) { return c.length >= 3; });
    list.forEach(function (c) { c.sort(function (x, y) { return (y.audience || 0) - (x.audience || 0); }); });
    list.sort(function (x, y) { return y.length - x.length; });
    return { list: list, root: find, parent: parent };
  }

  function buildInsights(ns, es, focus) {
    if (!insightBody || !insightPanel) return;
    insightBody.textContent = "";
    if (!ns.length) { insightPanel.hidden = true; return; }
    insightPanel.hidden = false;

    if (focus) buildEgoInsights(ns, es, focus);
    else buildFullInsights(ns, es);
  }

  function buildEgoInsights(ns, es, focus) {
    var ego = null;
    ns.forEach(function (n) { if (n.login === focus) ego = n; });
    if (!ego) return;
    var neigh = [];
    es.forEach(function (e) {
      var other = e.a === ego.id ? byId[e.b] : (e.b === ego.id ? byId[e.a] : null);
      if (other) neigh.push({ n: other, shared: e.shared || 0, share: e.share || 0 });
    });
    if (!neigh.length) {
      var s0 = section("Пересечений пока нет");
      line(s0, "Канал ещё не набрал общих чаттеров с другими каналами графа — загляните после пары эфиров.", "dim");
      insightBody.appendChild(s0);
      return;
    }
    neigh.sort(function (x, y) { return y.shared - x.shared; });

    var s1 = section("Куда уходит аудитория " + ego.name, "доля = от аудитории меньшего канала в паре");
    neigh.slice(0, 6).forEach(function (x) {
      line(s1, x.n.name + " — " + fmtN(x.shared) + " общих · " + pct(x.share), "strong", x.n.login);
    });
    insightBody.appendChild(s1);

    var collab = neigh.filter(function (x) {
      var ratio = (x.n.audience || 1) / (ego.audience || 1);
      return ratio >= 0.33 && ratio <= 3 && x.share >= 0.08;
    }).slice(0, 4);
    if (collab.length) {
      var s2 = section("Коллаб / рейд-кандидаты", "сопоставимый размер + тёплая общая аудитория → максимальная конверсия рейда");
      collab.forEach(function (x) {
        line(s2, x.n.name + " · аудитория " + fmtN(x.n.audience) + " · " + pct(x.share) + " общих", "ok");
        focusLink(s2, x.n.login, "смотреть паутинку " + x.n.login + " →");
      });
      insightBody.appendChild(s2);
    }

    var donors = neigh.filter(function (x) { return (x.n.audience || 0) >= 2 * (ego.audience || 1); }).slice(0, 4);
    if (donors.length) {
      var s3 = section("Доноры роста", "крупные каналы, где ваша аудитория уже сидит — там вас найдут");
      donors.forEach(function (x) {
        line(s3, x.n.name + " · аудитория " + fmtN(x.n.audience) + " · " + fmtN(x.shared) + " общих", "ok", x.n.login);
      });
      insightBody.appendChild(s3);
    }

    var anom = neigh.filter(function (x) { return x.share >= 0.6 && Math.min(x.n.audience || 0, ego.audience || 0) >= 50; });
    if (anom.length) {
      var s4 = section("Сигнал внимания");
      anom.slice(0, 3).forEach(function (x) {
        line(s4, "С каналом " + x.n.name + " общие " + pct(x.share) + " аудитории меньшего — аномально высокая общность.", "warn");
      });
      insightBody.appendChild(s4);
    }
  }

  // «Проверить пару» — the direct brand question: how much do channels A and B share?
  // Answered from the loaded edge set; absent edge → honest note + the exact /overlap tool link.
  function buildPairCheck() {
    var s = section("Проверить пару каналов", "сколько аудитории у двух каналов общее");
    var wrap = el("div", "display:flex;gap:6px;align-items:center;");
    var mk = function (ph) {
      var i = document.createElement("input");
      i.type = "text"; i.placeholder = ph;
      i.style.cssText = "flex:1;min-width:0;background:#0F0F16;color:#F4F4F7;border:1px solid #25252F;" +
        "border-radius:8px;padding:7px 9px;font-size:12px;font-family:inherit;outline:none;";
      return i;
    };
    var ia = mk("логин A"), ib = mk("логин B");
    var btn = el("button", "padding:7px 11px;border-radius:8px;border:0;background:#7B5CFA;color:#fff;" +
      "font-size:12px;font-weight:600;cursor:pointer;font-family:inherit;", "OK");
    btn.type = "button";
    wrap.appendChild(ia); wrap.appendChild(ib); wrap.appendChild(btn);
    s.appendChild(wrap);
    var out = el("div", "font-size:12px;line-height:1.45;color:#C7C7D1;");
    s.appendChild(out);
    function check() {
      var a = ia.value.trim().toLowerCase(), b = ib.value.trim().toLowerCase();
      if (!a || !b) { out.textContent = "Введите оба логина."; return; }
      var na = null, nb = null;
      raw.nodes.forEach(function (n) { if (n.login === a) na = n; if (n.login === b) nb = n; });
      var edge = null;
      if (na && nb) raw.edges.forEach(function (e) {
        if ((e.a === na.id && e.b === nb.id) || (e.a === nb.id && e.b === na.id)) edge = e;
      });
      out.textContent = "";
      if (edge) {
        out.appendChild(el("div", "color:#F4F4F7;font-weight:600;",
          a + " ↔ " + b + ": " + fmtN(edge.shared) + " общих · " + pct(edge.share || 0) + " аудитории меньшего"));
      } else {
        out.appendChild(el("div", "color:#8E8A9A;",
          (na && nb ? "В текущем графе пересечение этой пары не найдено (ниже порога или вне топ-200)."
                    : "Канал" + (!na && !nb ? "ы не найдены" : (!na ? " " + a : " " + b) + " не найден") + " в графе.")));
      }
      var link = el("a", "display:inline-block;margin-top:4px;font-size:12px;color:#A78BFA;text-decoration:none;",
        "Точный пересчёт пары в оверлапе →");
      link.href = APP_PREFIX + "/overlap?channels=" + encodeURIComponent(a) + "," + encodeURIComponent(b);
      out.appendChild(link);
    }
    btn.addEventListener("click", check);
    [ia, ib].forEach(function (i) { i.addEventListener("keydown", function (e) { if (e.key === "Enter") check(); }); });
    insightBody.appendChild(s);
  }

  function buildFullInsights(ns, es) {
    buildPairCheck();
    var com = communities(ns, es);

    if (com.list.length) {
      var s1 = section("Сообщества аудиторий", "каналы, связанные сильнейшими пересечениями");
      com.list.slice(0, 5).forEach(function (c) {
        var core = c.slice(0, 2).map(function (n) { return n.name; }).join(" + ");
        var sum = c.reduce(function (acc, n) { return acc + (n.audience || 0); }, 0);
        line(s1, c.length + " каналов вокруг " + core + " · сумма аудиторий " + fmtN(sum), "strong");
      });
      insightBody.appendChild(s1);
    }

    // Bridges: nodes whose meaningful edges span 2+ communities — the widest-reach placements.
    var compOf = {};
    com.list.forEach(function (c, i) { c.forEach(function (n) { compOf[n.id] = i; }); });
    var span = {};
    es.forEach(function (e) {
      if ((e.share || 0) < 0.05) return;
      var ca = compOf[e.a], cb = compOf[e.b];
      if (ca == null || cb == null || ca === cb) return;
      (span[e.a] = span[e.a] || {})[cb] = true;
      (span[e.b] = span[e.b] || {})[ca] = true;
    });
    var bridges = ns.filter(function (n) { return span[n.id] && Object.keys(span[n.id]).length >= 2; })
      .sort(function (x, y) { return (y.audience || 0) - (x.audience || 0); });
    if (bridges.length) {
      var s2 = section("Мосты между сообществами", "аудитория этих каналов дотягивается сразу до нескольких кластеров");
      bridges.slice(0, 4).forEach(function (n) {
        line(s2, n.name + " · аудитория " + fmtN(n.audience) + " · соединяет " + Object.keys(span[n.id]).length + "+ сообществ", "ok", n.login);
      });
      insightBody.appendChild(s2);
    }

    // Unique reach (brand value): big audience, low max overlap → placements that don't duplicate.
    var maxPortion = {};
    es.forEach(function (e) {
      var a = byId[e.a], b = byId[e.b];
      if (!a || !b) return;
      if (a.audience) maxPortion[a.id] = Math.max(maxPortion[a.id] || 0, (e.shared || 0) / a.audience);
      if (b.audience) maxPortion[b.id] = Math.max(maxPortion[b.id] || 0, (e.shared || 0) / b.audience);
    });
    var uniq = ns.filter(function (n) { return (n.audience || 0) >= 100; })
      .map(function (n) {
        var mp = Math.min(1, maxPortion[n.id] || 0);
        return { n: n, mp: mp, core: Math.round((n.audience || 0) * (1 - mp)) };
      })
      .sort(function (x, y) { return y.core - x.core; });
    if (uniq.length) {
      var s3 = section("Уникальный охват — где реклама не дублируется", "оценка ядра, которое не пересекается с другими каналами графа");
      uniq.slice(0, isBrand ? 6 : 2).forEach(function (x) {
        line(s3, x.n.name + " · аудитория " + fmtN(x.n.audience) + " · макс. пересечение " + pct(x.mp) +
          " → уникальное ядро ≈ " + fmtN(x.core), "strong", x.n.login);
      });
      brandGate(s3, 2, Math.min(uniq.length, 6), "каналов");
      insightBody.appendChild(s3);
    }

    // Anomalous overlaps (bot lens, legal-safe wording).
    var anomPairs = es.filter(function (e) {
      var a = byId[e.a], b = byId[e.b];
      return a && b && (e.share || 0) >= 0.6 && Math.min(a.audience || 0, b.audience || 0) >= 50;
    }).sort(function (x, y) { return (y.share || 0) - (x.share || 0); });
    if (anomPairs.length) {
      var s4 = section("Аномально высокая общность", "у меньшего канала в паре большинство аудитории — общее; сигнал внимания");
      anomPairs.slice(0, isBrand ? 5 : 2).forEach(function (e) {
        line(s4, byId[e.a].name + " ↔ " + byId[e.b].name + " · " + pct(e.share) + " общих", "warn");
      });
      brandGate(s4, 2, Math.min(anomPairs.length, 5), "пар");
      insightBody.appendChild(s4);
    }
  }

  function resize() {
    var r = canvas.parentElement.getBoundingClientRect();
    canvas.width = r.width * devicePixelRatio;
    canvas.height = r.height * devicePixelRatio;
    canvas.style.width = r.width + "px";
    canvas.style.height = r.height + "px";
  }
  window.addEventListener("resize", function () { resize(); draw(); });

  function setNote(text) { if (note) { note.textContent = text || ""; note.hidden = !text; } }

  function load(focus) {
    setNote(focus ? "Строим паутинку канала " + focus + "…" : "Строим граф по свежим данным…");
    var url = "/api/v1/graph/audience" + (focus ? "?focus=" + encodeURIComponent(focus) : "");
    fetch(url, { headers: { Accept: "application/json" }, credentials: "same-origin" })
      .then(function (r) {
        if (r.status === 401) { window.location.href = "/login"; throw "auth"; }
        if (r.status === 404) { setNote("Канал не найден в графе"); throw "nf"; }
        if (!r.ok) throw "http" + r.status;
        return r.json();
      })
      .then(function (resp) {
        var d = (resp && resp.data) || {};
        raw = { nodes: d.nodes || [], edges: d.edges || [], focus: focus || null };
        applyFilters();
      })
      .catch(function (e) { if (e !== "auth" && e !== "nf") setNote("Не удалось построить граф — попробуйте обновить"); });
  }

  function start(ns, es, focus) {
    resize();
    var W = canvas.width / devicePixelRatio, H = canvas.height / devicePixelRatio;
    if (!ns.length) { setNote(focus ? "У канала пока нет пересечений — загляните позже" : "Пока нет данных для графа"); nodes = []; edges = []; draw(); return; }
    setNote("");
    var maxA = Math.max.apply(null, ns.map(function (n) { return n.audience || 1; }));
    nodes = ns.map(function (n, i) {
      var angle = (i / ns.length) * Math.PI * 2;
      return { id: n.id, login: n.login, name: n.name, audience: n.audience, band: n.band,
               r: 4 + 22 * Math.sqrt((n.audience || 1) / maxA),
               x: W / 2 + Math.cos(angle) * Math.min(W, H) * 0.33,
               y: H / 2 + Math.sin(angle) * Math.min(W, H) * 0.33, vx: 0, vy: 0,
               focus: focus && n.login === focus };
    });
    byId = {};
    nodes.forEach(function (n) { byId[n.id] = n; });
    edges = es.filter(function (e) { return byId[e.a] && byId[e.b]; });
    view = { x: 0, y: 0, k: 1 };
    alpha = 1;
    if (raf) cancelAnimationFrame(raf);
    tick();
  }

  function tick() {
    var W = canvas.width / devicePixelRatio, H = canvas.height / devicePixelRatio;
    // pairwise repulsion (O(n²) — n ≤ ~200, fine), spring edges, centering
    for (var i = 0; i < nodes.length; i++) {
      var a = nodes[i];
      for (var j = i + 1; j < nodes.length; j++) {
        var b = nodes[j];
        var dx = a.x - b.x, dy = a.y - b.y;
        var d2 = dx * dx + dy * dy + 0.01, d = Math.sqrt(d2);
        var f = 1400 / d2;
        var fx = (dx / d) * f, fy = (dy / d) * f;
        a.vx += fx; a.vy += fy; b.vx -= fx; b.vy -= fy;
      }
      a.vx += (W / 2 - a.x) * 0.0015;
      a.vy += (H / 2 - a.y) * 0.0015;
    }
    edges.forEach(function (e) {
      var a = byId[e.a], b = byId[e.b];
      var dx = b.x - a.x, dy = b.y - a.y;
      var d = Math.sqrt(dx * dx + dy * dy) + 0.01;
      var target = 90 + 140 * (1 - Math.min(1, (e.share || 0) * 2));
      var f = (d - target) * 0.004 * (0.4 + Math.min(1, (e.share || 0) * 3));
      var fx = (dx / d) * f, fy = (dy / d) * f;
      a.vx += fx; a.vy += fy; b.vx -= fx; b.vy -= fy;
    });
    nodes.forEach(function (n) {
      n.x += n.vx * alpha; n.y += n.vy * alpha;
      n.vx *= 0.82; n.vy *= 0.82;
    });
    alpha = Math.max(0.02, alpha * 0.995);
    draw();
    raf = requestAnimationFrame(tick);
  }

  function draw() {
    var W = canvas.width, H = canvas.height;
    ctx.setTransform(1, 0, 0, 1, 0, 0);
    ctx.clearRect(0, 0, W, H);
    ctx.setTransform(devicePixelRatio * view.k, 0, 0, devicePixelRatio * view.k,
                     devicePixelRatio * view.x, devicePixelRatio * view.y);
    var hoverSet = null;
    if (hover) {
      hoverSet = {};
      hoverSet[hover.id] = true;
      edges.forEach(function (e) {
        if (e.a === hover.id) hoverSet[e.b] = true;
        if (e.b === hover.id) hoverSet[e.a] = true;
      });
    }
    edges.forEach(function (e) {
      var a = byId[e.a], b = byId[e.b];
      var lit = hoverSet && (e.a === hover.id || e.b === hover.id);
      ctx.strokeStyle = lit ? "rgba(124,58,237,0.75)" : "rgba(255,255,255,0.07)";
      ctx.lineWidth = 0.5 + Math.min(6, (e.share || 0) * 14);
      ctx.beginPath(); ctx.moveTo(a.x, a.y); ctx.lineTo(b.x, b.y); ctx.stroke();
    });
    nodes.forEach(function (n) {
      var dimmed = hoverSet && !hoverSet[n.id];
      ctx.globalAlpha = dimmed ? 0.18 : 1;
      ctx.fillStyle = BAND_HEX[n.band] || BAND_HEX.grey;
      ctx.beginPath(); ctx.arc(n.x, n.y, n.r, 0, Math.PI * 2); ctx.fill();
      if (n.focus) { ctx.strokeStyle = "#7C3AED"; ctx.lineWidth = 3; ctx.stroke(); }
      if (selected[n.login]) { // media-set pick (shift+click)
        ctx.strokeStyle = "#C9B8FF"; ctx.lineWidth = 2.5;
        ctx.beginPath(); ctx.arc(n.x, n.y, n.r + 4, 0, Math.PI * 2); ctx.stroke();
      }
      if (n.hl) { // search match
        ctx.strokeStyle = "#FFFFFF"; ctx.lineWidth = 2;
        ctx.beginPath(); ctx.arc(n.x, n.y, n.r + 7, 0, Math.PI * 2); ctx.stroke();
      }
      if (n.r > 9 || n.focus || n.hl || selected[n.login] || (hoverSet && hoverSet[n.id])) {
        ctx.fillStyle = "#F4F4F7";
        ctx.font = "11px Inter, system-ui, sans-serif";
        ctx.textAlign = "center";
        ctx.fillText(n.login, n.x, n.y - n.r - 5);
      }
      ctx.globalAlpha = 1;
    });
  }

  function toWorld(ev) {
    var r = canvas.getBoundingClientRect();
    return { x: (ev.clientX - r.left - view.x) / view.k, y: (ev.clientY - r.top - view.y) / view.k };
  }
  function nodeAt(p) {
    for (var i = nodes.length - 1; i >= 0; i--) {
      var n = nodes[i], dx = p.x - n.x, dy = p.y - n.y;
      if (dx * dx + dy * dy <= (n.r + 4) * (n.r + 4)) return n;
    }
    return null;
  }

  canvas.addEventListener("mousemove", function (ev) {
    if (dragging && dragStart) {
      view.x += ev.clientX - dragStart.x; view.y += ev.clientY - dragStart.y;
      dragStart = { x: ev.clientX, y: ev.clientY };
      draw(); return;
    }
    var n = nodeAt(toWorld(ev));
    if (n !== hover) { hover = n; draw(); }
    if (tip) {
      if (n) {
        var deg = edges.filter(function (e) { return e.a === n.id || e.b === n.id; }).length;
        tip.textContent = n.name + " · аудитория чата " + n.audience.toLocaleString("ru-RU") +
          " · связей " + deg + " · клик = паутинка, двойной = карточка";
        tip.style.left = (ev.clientX - canvas.getBoundingClientRect().left + 14) + "px";
        tip.style.top = (ev.clientY - canvas.getBoundingClientRect().top + 14) + "px";
        tip.hidden = false;
      } else tip.hidden = true;
    }
    canvas.style.cursor = n ? "pointer" : dragging ? "grabbing" : "grab";
  });
  canvas.addEventListener("mousedown", function (ev) {
    if (!nodeAt(toWorld(ev))) { dragging = true; dragStart = { x: ev.clientX, y: ev.clientY }; }
  });
  window.addEventListener("mouseup", function () { dragging = false; dragStart = null; });
  canvas.addEventListener("click", function (ev) {
    var n = nodeAt(toWorld(ev));
    if (!n || dragging) return;
    if (ev.shiftKey) { // add/remove from the comparison media-set instead of switching to ego
      if (selected[n.login]) delete selected[n.login];
      else selected[n.login] = true;
      renderSelChips();
      draw();
      return;
    }
    if (focusInput) focusInput.value = n.login;
    load(n.login);
  });

  // Touch support: the graph must work on phones/tablets too (canvas mouse events don't fire there).
  // One-finger drag pans (or taps a node = the click behavior); pinch zoom is left to page zoom.
  var touchStart = null, touchMoved = false;
  canvas.addEventListener("touchstart", function (ev) {
    if (ev.touches.length !== 1) return;
    var t = ev.touches[0];
    touchStart = { x: t.clientX, y: t.clientY };
    touchMoved = false;
  }, { passive: true });
  canvas.addEventListener("touchmove", function (ev) {
    if (!touchStart || ev.touches.length !== 1) return;
    var t = ev.touches[0];
    if (Math.abs(t.clientX - touchStart.x) + Math.abs(t.clientY - touchStart.y) > 6) touchMoved = true;
    view.x += t.clientX - touchStart.x;
    view.y += t.clientY - touchStart.y;
    touchStart = { x: t.clientX, y: t.clientY };
    draw();
    ev.preventDefault();
  }, { passive: false });
  canvas.addEventListener("touchend", function (ev) {
    if (!touchStart) return;
    if (!touchMoved) {
      var n = nodeAt(toWorld({ clientX: touchStart.x, clientY: touchStart.y }));
      if (n) { if (focusInput) focusInput.value = n.login; load(n.login); }
    }
    touchStart = null;
  });
  // Host-aware card link: production keeps the canonical apex URL, staging/localhost open the
  // relative /c/ card on the same host (a hardcoded prod apex 404s the flow off-prod).
  var CARD_BASE = /(^|\.)himrate\.com$/.test(window.location.hostname) ? "https://himrate.com" : "";
  canvas.addEventListener("dblclick", function (ev) {
    var n = nodeAt(toWorld(ev));
    if (n) window.open(CARD_BASE + "/c/" + encodeURIComponent(n.login), "_blank", "noopener");
  });
  canvas.addEventListener("wheel", function (ev) {
    ev.preventDefault();
    var r = canvas.getBoundingClientRect();
    var mx = ev.clientX - r.left, my = ev.clientY - r.top;
    var k2 = Math.min(4, Math.max(0.25, view.k * (ev.deltaY < 0 ? 1.12 : 0.89)));
    view.x = mx - ((mx - view.x) / view.k) * k2;
    view.y = my - ((my - view.y) / view.k) * k2;
    view.k = k2;
    draw();
  }, { passive: false });

  if (focusInput) focusInput.addEventListener("keydown", function (e) {
    if (e.key === "Enter" && focusInput.value.trim()) load(focusInput.value.trim().toLowerCase());
  });
  if (resetBtn) resetBtn.addEventListener("click", function () { if (focusInput) focusInput.value = ""; load(null); });

  // Auth gate: ONLY the lk/status probe (and its own network failure) decides the /login redirect.
  // Boot/data errors show the honest graph note instead of bouncing the user to /login.
  fetch("/api/v1/lk/status", { headers: { Accept: "application/json" }, credentials: "same-origin" })
    .then(function (r) { return r.ok ? r.json() : {}; })
    .then(
      function (s) {
        if (!s || !s.authenticated) { window.location.href = "/login"; return; }
        isBrand = ((s.roles || []).indexOf("brand") !== -1);
        try {
          buildToolbar();
          resize();
          // Deep link: /graph?focus=<login> (ego mode from channel cards / brand surfaces).
          var qf = new URLSearchParams(window.location.search).get("focus");
          if (qf && focusInput) focusInput.value = qf;
          load(qf ? qf.toLowerCase() : null);
        } catch (e) {
          setNote("Не удалось построить граф — попробуйте обновить");
        }
      },
      function () { window.location.href = "/login"; }
    );
})();
