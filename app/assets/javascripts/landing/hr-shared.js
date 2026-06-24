/* HimRate — shared landing enhancement layer (Rails port of the Pencil export's
   hr-shared.js). PORTING NOTE (TASK-060 Phase 1):
     - The export's fixHeader() (runtime header build), applyLang() (client-side
       i18n text-swap) and text-matched wireNav() are intentionally NOT ported:
       in Rails those concerns are server-side — the header is baked into the ERB,
       i18n is Rails I18n (?locale=), and navigation uses real hrefs (data-hr-href).
     - Everything below (animated dot background, scroll reveals, count-up, card
       hover, leaving transition, injected keyframes/CSS) is the genuine client
       visual layer and is ported verbatim from the export.

   Per-page config BEFORE this script:
     window.HR = { word:'ЖИВЫЕ', accent:['34,211,238','99,102,241'], styles:[0,2,3] };
   Falls back to sensible defaults if HR is missing. */
(function () {
  var CFG = window.HR || {};
  var ROOT_SEL = CFG.root || null;
  var WORD = CFG.word || 'HimRate';
  var COLS = (CFG.accent && CFG.accent.length) ? CFG.accent : ['34,211,238', '99,102,241'];
  var SHAPE = CFG.shape || null;

  /* ---- glyph shapes drawn onto the offscreen canvas (white = dotted) ---- */
  var SHAPES = {
    graph: function (ox, cx, cy, S) {
      ox.strokeStyle = '#fff'; ox.lineJoin = 'round'; ox.lineCap = 'round';
      var x0 = cx - S * 0.46, y0 = cy + S * 0.34, w = S * 0.92, h = S * 0.62;
      ox.lineWidth = S * 0.028; ox.beginPath(); ox.moveTo(x0, y0 - h); ox.lineTo(x0, y0); ox.lineTo(x0 + w, y0); ox.stroke();
      var pts = [[0, 0.1], [0.22, 0.32], [0.42, 0.24], [0.62, 0.6], [0.82, 0.72], [1, 0.98]];
      ox.lineWidth = S * 0.08; ox.beginPath();
      for (var i = 0; i < pts.length; i++) { var px = x0 + pts[i][0] * w, py = y0 - pts[i][1] * h; if (i === 0) ox.moveTo(px, py); else ox.lineTo(px, py); }
      ox.stroke();
      var ex = x0 + w, ey = y0 - 0.98 * h; ox.lineWidth = S * 0.07; ox.beginPath(); ox.moveTo(ex - S * 0.16, ey - S * 0.02); ox.lineTo(ex, ey); ox.lineTo(ex - S * 0.02, ey + S * 0.16); ox.stroke();
    },
    bars: function (ox, cx, cy, S) {
      ox.fillStyle = '#fff'; var n = 5, cell = S / n, bw = cell * 0.58, Hgt = S * 0.82, y0 = cy + S * 0.44, x0 = cx - S * 0.5 + cell * 0.21;
      var hs = [0.34, 0.52, 0.7, 0.86, 1.0];
      for (var i = 0; i < n; i++) { var bh = hs[i] * Hgt; ox.fillRect(x0 + i * cell, y0 - bh, bw, bh); }
    },
    play: function (ox, cx, cy, S) {
      ox.strokeStyle = '#fff'; ox.fillStyle = '#fff'; ox.lineWidth = S * 0.07;
      ox.beginPath(); ox.arc(cx, cy, S * 0.42, 0, 6.2832); ox.stroke();
      var t = S * 0.21; ox.beginPath(); ox.moveTo(cx - t * 0.55, cy - t); ox.lineTo(cx - t * 0.55, cy + t); ox.lineTo(cx + t * 0.98, cy); ox.closePath(); ox.fill();
    },
    gauge: function (ox, cx, cy, S) {
      ox.strokeStyle = '#fff'; ox.fillStyle = '#fff'; ox.lineCap = 'round';
      var R = S * 0.42, yc = cy + S * 0.18;
      ox.lineWidth = S * 0.09; ox.beginPath(); ox.arc(cx, yc, R, Math.PI, 2 * Math.PI); ox.stroke();
      var ang = 1.7 * Math.PI; ox.lineWidth = S * 0.05; ox.beginPath(); ox.moveTo(cx, yc); ox.lineTo(cx + Math.cos(ang) * R * 0.9, yc + Math.sin(ang) * R * 0.9); ox.stroke();
      ox.beginPath(); ox.arc(cx, yc, S * 0.06, 0, 6.2832); ox.fill();
    },
    live: function (ox, cx, cy, S) {
      ox.fillStyle = '#fff'; ox.textBaseline = 'middle'; ox.textAlign = 'left';
      var fs = S * 0.42; ox.font = '800 ' + fs + 'px "Space Grotesk","Geist Mono",Georgia,sans-serif';
      var label = 'LIVE', tw = ox.measureText(label).width, dotR = S * 0.14, gap = S * 0.16;
      var total = dotR * 2 + gap + tw, x0 = cx - total / 2, mid = cy;
      ox.beginPath(); ox.arc(x0 + dotR, mid, dotR, 0, 6.2832); ox.fill();
      ox.fillText(label, x0 + dotR * 2 + gap, mid);
    },
    chat: function (ox, cx, cy, S) {
      ox.strokeStyle = '#fff'; ox.fillStyle = '#fff'; ox.lineJoin = 'round';
      function bubble(bx, by, bw, bh, tailLeft) {
        var r = bh * 0.42; ox.lineWidth = S * 0.04;
        ox.beginPath(); ox.moveTo(bx + r, by);
        ox.arcTo(bx + bw, by, bx + bw, by + bh, r); ox.arcTo(bx + bw, by + bh, bx, by + bh, r);
        ox.arcTo(bx, by + bh, bx, by, r); ox.arcTo(bx, by, bx + bw, by, r); ox.closePath(); ox.stroke();
        ox.beginPath();
        if (tailLeft) { ox.moveTo(bx + bw * 0.30, by + bh - 1); ox.lineTo(bx + bw * 0.14, by + bh + bh * 0.5); ox.lineTo(bx + bw * 0.5, by + bh - 1); }
        else { ox.moveTo(bx + bw * 0.5, by + bh - 1); ox.lineTo(bx + bw * 0.86, by + bh + bh * 0.5); ox.lineTo(bx + bw * 0.7, by + bh - 1); }
        ox.closePath(); ox.fill();
        for (var i = 0; i < 3; i++) { ox.beginPath(); ox.arc(bx + bw * 0.32 + i * bw * 0.18, by + bh * 0.52, bh * 0.11, 0, 6.2832); ox.fill(); }
      }
      var w = S * 0.66, h = S * 0.3;
      bubble(cx - S * 0.48, cy - S * 0.4, w, h, true);
      bubble(cx - S * 0.18, cy + S * 0.06, w, h, false);
    }
  };

  function $(s, r) { return (r || document).querySelector(s); }
  function $all(s, r) { return Array.prototype.slice.call((r || document).querySelectorAll(s)); }
  function cls(el) { return (typeof el.className === 'string') ? el.className : ''; }

  /* ---------------- styles ---------------- */
  function injectCSS() {
    if (document.getElementById('hr-shared-style')) return;
    var s = document.createElement('style'); s.id = 'hr-shared-style';
    s.textContent = [
      '[data-hr-link]{ cursor:pointer; transition: opacity .15s ease; }',
      '[data-hr-link]:hover{ opacity:.62; }',
      '[data-hr-btn]{ cursor:pointer; transition: transform .13s ease, filter .15s ease, box-shadow .15s ease; }',
      '[data-hr-btn]:hover{ transform: translate(-1px,-2px); filter: brightness(1.08); box-shadow: 0 0 0 1.7px #7C3AED, 0 8px 22px #7C3AED44; }',
      '[data-hr-btn]:active{ transform: translate(0,0) scale(.985); filter: brightness(.95); box-shadow:none; }',
      '[data-hr-btn]:has([data-hr-cta]):hover{ box-shadow:none; transform:none; filter:none; }',
      '[data-hr-cta]{ cursor:pointer; transition: color .15s ease, box-shadow .15s ease; border-radius:6px; padding:3px 7px; margin:-3px -7px; }',
      '[data-hr-cta]:hover{ box-shadow: 0 0 0 2px #8B5CF6; background: rgba(124,58,237,.14); }',
      '[data-hr-card]{ transition: transform .2s cubic-bezier(.4,0,.2,1), box-shadow .2s ease; }',
      '[data-hr-card]:hover{ transform: translateY(-3px); box-shadow: 0 0 0 1.6px #7C3AED, 0 18px 44px -14px rgba(124,58,237,.55); }',
      '[data-hr-reveal]{ opacity:0; transform:translateY(16px); transition: opacity .7s cubic-bezier(.2,.6,.2,1), transform .7s cubic-bezier(.2,.6,.2,1); }',
      '[data-hr-reveal].hr-in{ opacity:1; transform:none; }',
      'body{ transition: opacity .28s ease; }',
      'body.hr-leaving{ opacity:0; }',
      'html, body{ scroll-behavior:smooth; }',
      '#hr-bgfx{ position:fixed; inset:0; z-index:0; pointer-events:none; background:#07070C; overflow:hidden; }',
      '#hr-bgfx canvas{ position:absolute; inset:0; width:100%; height:100%; display:block; }'
    ].join('\n');
    (document.head || document.documentElement).appendChild(s);
  }

  /* ---------------- navigation (real hrefs; server-rendered) ----------------
     The export matched nav targets by text content and rebuilt routes in JS.
     In Rails the markup carries real targets via data-hr-href, so here we only
     keep the page-leaving fade transition. Same-page anchors smooth-scroll. */
  function wireNav() {
    window.__hrGo = function (href) {
      if (!href) return;
      if (href === location.pathname || href === '#' || href.charAt(0) === '#') {
        window.scrollTo({ top: 0, behavior: 'smooth' }); return;
      }
      document.body.classList.add('hr-leaving');
      setTimeout(function () { location.href = href; }, 240);
    };
    $all('[data-hr-href]').forEach(function (el) {
      if (el.__hrNav) return; el.__hrNav = 1;
      el.setAttribute('data-hr-link', '');
      el.addEventListener('click', function (e) {
        e.preventDefault(); e.stopPropagation();
        window.__hrGo(el.getAttribute('data-hr-href'));
      });
    });
  }

  /* Body CTAs: the export matched purple / rounded-verb buttons by text and gave
     them hover + routing. Header CTAs carry real data-hr-href (above); body CTA
     destinations are wired in a later phase (their target pages don't exist yet),
     so here we only restore hover feedback + scroll-to-top on click. */
  function wireCTAs() {
    var ROUND = /rounded-\[(6|8|10|12|999)px\]/;
    var CTA = /^(подключить|установить|начать|связаться|все тарифы|оформить|выбрать|как это работает|как мы измеряем|узнать|смотреть|посмотреть|открыть|запросить|войти|получить|попробовать|демо|я бренд|я зритель|я стример|выбрать план|перейти)/i;
    $all('div').forEach(function (el) {
      var c = cls(el); var purple = /bg-\[#7C3AED\]/.test(c); var txt = (el.textContent || '').trim();
      var verb = ROUND.test(c) && CTA.test(txt) && txt.length <= 64;
      if ((!purple && !verb) || txt.length === 0 || txt.length > 72) return;
      if (el.hasAttribute('data-hr-href') || el.querySelector('[data-hr-btn]')) return;
      el.setAttribute('data-hr-btn', '');
      el.addEventListener('click', function (e) { e.stopPropagation(); window.__hrGo('#'); });
    });
  }

  /* ---------------- card hover ---------------- */
  function tagCards(root) {
    var RND = /rounded-\[(10|12|14|16|18|20|24)px\]/;
    $all('div', root).forEach(function (el) {
      if (!RND.test(cls(el))) return;
      if (el.hasAttribute('data-hr-card')) return;
      var r = el.getBoundingClientRect();
      if (r.width < 150 || r.width > 760 || r.height < 90 || r.height > 640) return;
      var bg = getComputedStyle(el).backgroundColor || ''; var m = bg.match(/rgba?\((\d+),\s*(\d+),\s*(\d+)(?:,\s*([\d.]+))?/);
      if (!m) return; if (m[4] !== undefined && parseFloat(m[4]) < 0.04) return;     // essentially transparent
      if (el.querySelector('[data-hr-card]')) return;                            // outermost rounded card only
      el.setAttribute('data-hr-card', '');
    });
  }

  /* ---------------- reveal on scroll + count-up ---------------- */
  function fmtLike(sample, val) {
    var pre = (sample.match(/^[~$]/) || [''])[0];
    var suf = (sample.match(/[%x×+]$/) || [''])[0];
    var sep = sample.indexOf(' ') > -1 ? ' ' : (/\d \d/.test(sample) ? ' ' : (sample.indexOf(',') > -1 ? ',' : ''));
    var n = Math.round(val), s = String(n), o = '', c = 0;
    if (sep) { for (var i = s.length - 1; i >= 0; i--) { o = s[i] + o; if (++c % 3 === 0 && i > 0) o = sep + o; } } else o = s;
    return pre + o + suf;
  }
  function countUp(el) {
    if (el.__cu) return; var sample = (el.textContent || '').trim();
    if (sample.indexOf('.') > -1) return;                       // skip decimals
    var digits = sample.replace(/[^\d]/g, ''); if (!digits) return;
    var to = parseInt(digits, 10); if (!isFinite(to) || to < 10 || to > 9999999) return;
    el.__cu = 1; var st = Date.now(), dur = 1100;
    var iv = setInterval(function () { var p = Math.min(1, (Date.now() - st) / dur), e = 1 - Math.pow(1 - p, 3); el.textContent = fmtLike(sample, to * e); if (p >= 1) clearInterval(iv); }, 16);
  }
  function setupReveal(root) {
    var secs = $all(':scope > *', root);
    // also reveal the meaningful sub-sections one level down for longer pages
    if (secs.length <= 2) { var more = []; secs.forEach(function (s) { more = more.concat($all(':scope > *', s)); }); if (more.length) secs = more; }
    var H = window.innerHeight || 800;
    var io = new IntersectionObserver(function (ents) {
      ents.forEach(function (en) {
        if (!en.isIntersecting) return; var t = en.target;
        t.classList.add('hr-in');
        $all('div,span,p', t).forEach(function (le) {
          if (le.children.length) return;
          var f = parseFloat(getComputedStyle(le).fontSize) || 0; if (f < 34) return;
          var tx = (le.textContent || '').trim(); if (/^[~$]?\d[\d  .,]*[%x×+]?$/.test(tx)) countUp(le);
        });
        io.unobserve(t);
      });
    }, { threshold: 0.12, rootMargin: '0px 0px -8% 0px' });
    secs.forEach(function (s) {
      var r = s.getBoundingClientRect(); if (r.height < 24) return;
      if (r.top > H * 0.82) { s.setAttribute('data-hr-reveal', ''); } else { s.classList.add('hr-in'); }
      io.observe(s);
    });
  }

  /* ---------------- animated dot background ---------------- */
  var __bgInit = false;
  function bg() {
    var root = ROOT_SEL ? $(ROOT_SEL) : null;
    if (!root) { root = $all('body > div[data-pencil-name]')[0] || document.body; }
    var fx = document.getElementById('hr-bgfx');
    if (!fx) { fx = document.createElement('div'); fx.id = 'hr-bgfx'; document.body.insertBefore(fx, document.body.firstChild); }
    root.style.position = 'relative'; root.style.zIndex = '1'; root.style.background = 'transparent';
    var cleared = 0;
    $all('div', root).forEach(function (el) {
      var r = el.getBoundingClientRect(); if (r.width < 860 || r.height < 120) return;
      var m = (getComputedStyle(el).backgroundColor || '').match(/rgba?\((\d+),\s*(\d+),\s*(\d+)/); if (!m) return;
      if (+m[1] < 14 && +m[2] < 14 && +m[3] < 22) { el.style.background = 'transparent'; cleared++; }
    });
    if (!__bgInit) { __bgInit = true; initBgCanvas(fx); }
    return cleared > 0;
  }
  var MARK = [
    "m24.7 4.5 0.7 3.2c1 0.3 2 1.2 2 2.3 0 1.3-1.1 2.5-2.6 2.5-1.2 0-2.5-1-2.5-2.5 0-0.8 0.4-1.5 1.1-2l-0.7-3.2c-2.7 0.5-4.6 2.8-4.6 5.6 0 3.3 2.6 6.1 6 6.1 3.2 0 6-2.5 6.1-6 0.1-2.9-2.3-5.7-5.5-6z",
    "m22.4 2.6 1.9-0.4 0.4 2.2c-0.6-0.1-1.3 0-1.9 0.1l-0.4-1.9z",
    "m33.6 18.6c-1.4-1.2-4.8-2.6-7.4-0.6-2.6 2.2-4.2 5.8-4.6 12.3h19.3c-1.5-4.8-5.6-9.9-7.3-11.7z",
    "m14.7 26.2c-1.6 0.2-3.2 1.3-4 2.9h-6.4c-0.7 0-1.4-0.2-1-1.5 0.6-2.3 3.1-8.7 3.8-10.8 0.2-0.6 0.5-0.8 0.7-0.8 0.9 4 2.1 8.3 2.8 9l1.6-0.4-3.9-20-1.7 0.4c-0.1 2.8 0.4 6.6 1 9.7-0.7 0.2-1.2 0.6-1.6 1.3-0.9 1.9-3.8 9-4.1 11.7-0.3 1.2 0.3 2.6 2 2.6h15.1c0-2.3-2-4.1-4.3-4.1z"
  ];
  function sm(t) { t = t < 0 ? 0 : (t > 1 ? 1 : t); return t * t * (3 - 2 * t); }

  function initBgCanvas(fx) {
    var cv = document.createElement('canvas'); fx.appendChild(cv);
    try { document.querySelectorAll('[data-pencil-name="Dot BG"],[data-pencil-name="Dots BG"],[data-pencil-name="Dots"],[data-pencil-name="Particles"]').forEach(function (e) { e.style.display = 'none'; }); } catch (e) {}
    var ctx = cv.getContext('2d'); var DPR = Math.min(2, window.devicePixelRatio || 1);
    var W = 0, H = 0, N = 1900, dots = [], free = [];
    function drawLogo(ox, gx, gy) {
      var fs = Math.max(56, W * (CFG.logoScale || 0.115));
      ox.textBaseline = 'middle'; ox.textAlign = 'left'; ox.font = '800 ' + fs + 'px "Playfair Display", Georgia, serif';
      var textW = ox.measureText('HimRate').width, markH = fs * 1.2, markW = markH * (42 / 38), gap = fs * 0.3;
      var totalW = markW + gap + textW, sx = Math.round((W - totalW) / 2);
      try { ox.save(); ox.translate(sx, gy - markH / 2); ox.scale(markW / 42, markH / 38); for (var p = 0; p < MARK.length; p++) ox.fill(new Path2D(MARK[p])); ox.restore(); } catch (e) {}
      ox.fillText('HimRate', sx + markW + gap, gy);
    }
    function drawKind(ox, kind) {
      var gx = W / 2, gy = H * 0.5, S = Math.min(W * 0.46, 540);
      ox.fillStyle = '#fff'; ox.strokeStyle = '#fff';
      if (kind === 'logo') { drawLogo(ox, gx, gy); return; }
      if (kind.indexOf('word:') === 0) { var w = kind.slice(5); var fs = Math.max(64, Math.min(W * 0.17, 236)); ox.textAlign = 'center'; ox.textBaseline = 'middle'; ox.font = '800 ' + fs + 'px "Space Grotesk","Playfair Display",Georgia,sans-serif'; ox.fillText(w, gx, gy); return; }
      if (SHAPES[kind]) { SHAPES[kind](ox, gx, gy, S); return; }
      ox.textAlign = 'center'; ox.textBaseline = 'middle'; ox.font = '800 160px sans-serif'; ox.fillText(kind, gx, gy);
    }
    function sampleKind(kind) {
      if (kind === 'scatter') { var o = []; for (var q = 0; q < N; q++) o.push([Math.random() * W, Math.random() * H]); return { pts: o, cx: W / 2, cy: H / 2 }; }
      var oc = document.createElement('canvas'); oc.width = W; oc.height = H; var ox = oc.getContext('2d');
      drawKind(ox, kind);
      var d; try { d = ox.getImageData(0, 0, W, H).data; } catch (e) { return { pts: [], cx: W / 2, cy: H / 2 }; }
      var pts = [], step = Math.max(4, Math.round(Math.min(W, H) / 170));
      for (var yy = 0; yy < H; yy += step) { for (var xx = 0; xx < W; xx += step) { if (d[(yy * W + xx) * 4 + 3] > 128) pts.push([xx, yy]); } }
      var cx = 0, cy = 0, i; for (i = 0; i < pts.length; i++) { cx += pts[i][0]; cy += pts[i][1]; } if (pts.length) { cx /= pts.length; cy /= pts.length; }
      pts.sort(function (a, b) { return Math.atan2(a[1] - cy, a[0] - cx) - Math.atan2(b[1] - cy, b[0] - cx); });
      var out = []; if (pts.length) { for (i = 0; i < N; i++) out.push(pts[Math.floor(i * pts.length / N)]); }
      else { for (i = 0; i < N; i++) out.push([W / 2, H / 2]); }
      return { pts: out, cx: cx || W / 2, cy: cy || H / 2 };
    }
    var LOGO = null;
    function build() {
      W = window.innerWidth || 1440; H = window.innerHeight || 800;
      cv.width = W * DPR; cv.height = H * DPR; cv.style.width = W + 'px'; cv.style.height = H + 'px';
      ctx.setTransform(DPR, 0, 0, DPR, 0, 0);
      LOGO = sampleKind('logo');
      var jit = CFG.mirage ? 14 : 4;
      var prev = dots; dots = [];
      for (var i = 0; i < N; i++) {
        var p = prev[i];
        dots.push({
          hx: p ? p.hx : Math.random() * W, hy: p ? p.hy : Math.random() * H, ph: p ? p.ph : Math.random() * 6.2832,
          sp: p ? p.sp : (0.32 + Math.random() * 0.8), r: p ? p.r : (0.8 + Math.random() * 1.3), dir: p ? p.dir : (Math.random() < 0.5 ? -1 : 1),
          jx: p ? p.jx : ((Math.random() * 2 - 1) * jit), jy: p ? p.jy : ((Math.random() * 2 - 1) * jit),
          col: p ? p.col : (COLS[Math.random() < 0.5 ? 0 : 1])
        });
      }
      if (free.length === 0) {
        for (var j = 0; j < 2700; j++) { free.push({ hx: Math.random() * W, hy: Math.random() * H, ph: Math.random() * 6.2832, sp: 0.22 + Math.random() * 0.7, r: 0.7 + Math.random() * 1.2, col: (COLS[Math.random() < 0.5 ? 0 : 1]) }); }
      } else { for (var f2 = 0; f2 < free.length; f2++) { if (free[f2].hx > W) free[f2].hx = Math.random() * W; if (free[f2].hy > H) free[f2].hy = Math.random() * H; } }
    }
    function morph(x0, y0, x1, y1, e, style, dot, pvx, pvy) {
      if (style === 'stream') { var lt = sm((e - (x1 / (W || 1)) * 0.45) / 0.55); return [x0 + (x1 - x0) * lt, y0 + (y1 - y0) * lt]; }
      var x = x0 + (x1 - x0) * e, y = y0 + (y1 - y0) * e;
      if (style === 'swirl') { var vx = -(y1 - y0), vy = (x1 - x0), vl = Math.sqrt(vx * vx + vy * vy) || 1, sw = Math.sin(e * Math.PI) * 52 * dot.dir; return [x + vx / vl * sw, y + vy / vl * sw]; }
      if (style === 'orbit') { var a = Math.sin(e * Math.PI) * 0.7 * dot.dir, dx = x - pvx, dy = y - pvy, ca = Math.cos(a), sa = Math.sin(a); return [pvx + dx * ca - dy * sa, pvy + dx * sa + dy * ca]; }
      return [x, y];
    }
    function frame() {
      var y = window.scrollY || document.documentElement.scrollTop || 0;
      var maxH = Math.max(1, (document.body.scrollHeight || document.documentElement.scrollHeight) - window.innerHeight);
      var fr = Math.max(0, Math.min(1, y / maxH));
      var ats = (CFG.assembleAts && CFG.assembleAts.length) ? CFG.assembleAts : [(CFG.assembleAt != null ? CFG.assembleAt : 0.5)];
      var halfW = (CFG.assembleWidth != null ? CFG.assembleWidth : 0.16);
      var af = 0;
      for (var ai = 0; ai < ats.length; ai++) { var dd2 = Math.abs(fr - ats[ai]) / halfW; if (dd2 < 1) { var a2 = sm(1 - dd2); if (a2 > af) af = a2; } }
      var mirage = !!CFG.mirage;
      var time = Date.now() * 0.001;
      var pvx = W / 2, pvy = H * 0.46;
      ctx.clearRect(0, 0, W, H);
      for (var f = 0; f < free.length; f++) {
        var ff = free[f];
        var fax = ff.hx + Math.sin(time * ff.sp + ff.ph) * 32, fay = ff.hy + Math.cos(time * ff.sp * 0.9 + ff.ph) * 32;
        ctx.beginPath(); ctx.fillStyle = 'rgba(' + ff.col + ',0.154)'; ctx.arc(fax, fay, ff.r, 0, 6.2832); ctx.fill();
      }
      var amb = (1 - af) * 22 + 3;
      var maxA = mirage ? 0.238 : 0.546;
      for (var i = 0; i < dots.length; i++) {
        var dd = dots[i];
        var ox2 = Math.sin(time * dd.sp + dd.ph) * amb, oy2 = Math.cos(time * dd.sp * 0.9 + dd.ph) * amb;
        var x0 = dd.hx, y0 = dd.hy, x1 = LOGO.pts[i][0] + dd.jx, y1 = LOGO.pts[i][1] + dd.jy;
        var pp = morph(x0, y0, x1, y1, af, 'swirl', dd, pvx, pvy);
        var a = 0.084 + af * (maxA - 0.084);
        ctx.beginPath(); ctx.fillStyle = 'rgba(' + dd.col + ',' + a.toFixed(3) + ')'; ctx.arc(pp[0] + ox2, pp[1] + oy2, dd.r + af * 0.5, 0, 6.2832); ctx.fill();
      }
    }
    build();
    var rt; window.addEventListener('resize', function () { clearTimeout(rt); rt = setTimeout(build, 180); });
    if (fx.__loop) clearInterval(fx.__loop); fx.__loop = setInterval(frame, 33);
  }

  /* ---------------- boot ---------------- */
  function init() {
    injectCSS();
    wireNav();
    wireCTAs();
    var root = ROOT_SEL ? $(ROOT_SEL) : ($all('body > div[data-pencil-name]')[0] || document.body);
    var tries = 0;
    (function poll() { var ok = bg(); tagCards(root); if (ok || tries > 40) return; tries++; setTimeout(poll, 200); })();
    setupReveal(root);
    setTimeout(function () { tagCards(root); }, 900);
  }
  if (document.readyState === 'complete' || document.readyState === 'interactive') setTimeout(init, 300);
  else window.addEventListener('DOMContentLoaded', function () { setTimeout(init, 300); });
})();
