/* HimRate landing — responsive header burger + RU/EN switch (TASK-060).
   Loaded on every page (including index, which is self-contained and does not
   load hr-shared.js). Provides:
   1. the mobile burger overlay toggle,
   2. a fallback RU/EN i18n engine for pages without hr-shared.js (index), so the
      visible language switcher works everywhere.
   Nav-link routing stays owned by each page's own script. */
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

  /* RU/EN switch on pages without hr-shared.js (i.e. index). Delegates to the single
     canonical translator in hr-i18n.js (loaded before this file) — was a byte-identical
     copy of it; dedup'd to one source. */
  function installI18n() {
    if (typeof window.__hrSetLang === 'function') return; // hr-shared owns it
    function getLang() { try { return localStorage.getItem('hr-lang') || 'ru'; } catch (e) { return 'ru'; } }
    function applyLang(lang) { if (window.__hrApplyI18n) window.__hrApplyI18n(lang); }
    window.__hrSetLang = function (l) { l = (l === 'en') ? 'en' : 'ru'; try { localStorage.setItem('hr-lang', l); } catch (e) {} applyLang(l); };
    applyLang(getLang());
    setTimeout(function () { applyLang(getLang()); }, 600);
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
    // RU/EN switch — visible in the header; __hrSetLang now always exists.
    $all('[data-hr-lang-btn]').forEach(function (b) {
      if (b.__hrl) return; b.__hrl = 1;
      b.addEventListener('click', function (e) { e.stopPropagation(); if (typeof window.__hrSetLang === 'function') window.__hrSetLang(b.getAttribute('data-hr-lang-btn')); });
    });
  }

  // hr-shared/index scripts boot on a ~300-750ms delay; run after them so
  // __hrSetLang is defined by the time we decide whether to install the fallback.
  function boot() { setTimeout(function () { installI18n(); wire(); }, 900); }
  if (document.readyState === 'complete' || document.readyState === 'interactive') boot();
  else window.addEventListener('DOMContentLoaded', boot);
})();
