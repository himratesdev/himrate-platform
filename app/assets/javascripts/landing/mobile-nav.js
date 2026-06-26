/* HimRate landing — responsive header burger (TASK-060). Loaded on every page
   (including index, which is self-contained and does not load hr-shared.js).
   Toggles the mobile nav overlay; wires the RU/EN switch only where the page
   provides one (window.__hrSetLang, defined by hr-shared.js on the inner pages).
   Nav-link routing is owned by each page's own script. */
(function () {
  function $(s, r) { return (r || document).querySelector(s); }
  function $all(s, r) { return Array.prototype.slice.call((r || document).querySelectorAll(s)); }

  function injectCSS() {
    if (document.getElementById('hr-mnav-style')) return;
    var s = document.createElement('style');
    s.id = 'hr-mnav-style';
    s.textContent = [
      '[data-hr-menu].hr-open{ display:flex; }',
      '[data-hr-burger].hr-open{ background:#FFFFFF1F; }',
      '[data-hr-mlink]:active{ opacity:.6; }'
    ].join('\n');
    (document.head || document.documentElement).appendChild(s);
  }

  function wire() {
    injectCSS();
    var burger = $('[data-hr-burger]'), menu = $('[data-hr-menu]');
    if (burger && menu && !burger.__hrw) {
      burger.__hrw = 1;
      burger.addEventListener('click', function (e) {
        e.stopPropagation();
        var open = menu.classList.toggle('hr-open');
        burger.classList.toggle('hr-open', open);
      });
      menu.addEventListener('click', function (e) {
        if (e.target.closest('[data-hr-mlink],[data-pencil-name]')) {
          menu.classList.remove('hr-open'); burger.classList.remove('hr-open');
        }
      });
      document.addEventListener('click', function (e) {
        if (!menu.contains(e.target) && !burger.contains(e.target)) {
          menu.classList.remove('hr-open'); burger.classList.remove('hr-open');
        }
      });
      window.addEventListener('resize', function () {
        if (window.innerWidth >= 1024) { menu.classList.remove('hr-open'); burger.classList.remove('hr-open'); }
      });
    }
    // RU/EN switch: wire where the page provides a handler; otherwise hide it.
    var langBtns = $all('[data-hr-menu] [data-hr-lang-btn]');
    if (typeof window.__hrSetLang === 'function') {
      langBtns.forEach(function (b) {
        if (b.__hrl) return; b.__hrl = 1;
        b.addEventListener('click', function (e) { e.stopPropagation(); window.__hrSetLang(b.getAttribute('data-hr-lang-btn')); });
      });
    } else if (langBtns.length) {
      var row = langBtns[0].parentElement; if (row) row.style.display = 'none';
    }
  }

  // hr-shared/index scripts boot on a ~300-750ms delay; run after them so
  // __hrSetLang is defined by the time we decide whether to wire or hide RU/EN.
  function boot() { setTimeout(wire, 900); }
  if (document.readyState === 'complete' || document.readyState === 'interactive') boot();
  else window.addEventListener('DOMContentLoaded', boot);
})();
