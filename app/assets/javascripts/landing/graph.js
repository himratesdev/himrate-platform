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
        start(d.nodes || [], d.edges || [], focus);
        if (sub) {
          sub.textContent = (focus ? "Паутинка канала " + focus + " · " : "") +
            (d.nodes ? d.nodes.length : 0) + " каналов · " + (d.edges ? d.edges.length : 0) +
            " связей · основа: активность в чатах";
        }
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
      if (n.r > 9 || n.focus || (hoverSet && hoverSet[n.id])) {
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
    if (n && !dragging) { if (focusInput) focusInput.value = n.login; load(n.login); }
  });
  canvas.addEventListener("dblclick", function (ev) {
    var n = nodeAt(toWorld(ev));
    if (n) window.open("https://himrate.com/c/" + encodeURIComponent(n.login), "_blank", "noopener");
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

  fetch("/api/v1/lk/status", { headers: { Accept: "application/json" }, credentials: "same-origin" })
    .then(function (r) { return r.ok ? r.json() : {}; })
    .then(function (s) {
      if (!s || !s.authenticated) { window.location.href = "/login"; return; }
      resize();
      // Deep link: /graph?focus=<login> (ego mode from channel cards / brand surfaces).
      var qf = new URLSearchParams(window.location.search).get("focus");
      if (qf && focusInput) focusInput.value = qf;
      load(qf ? qf.toLowerCase() : null);
    })
    .catch(function () { window.location.href = "/login"; });
})();
