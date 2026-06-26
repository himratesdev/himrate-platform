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

  /* Fallback RU/EN engine — installed only when the page has no hr-shared.js
     (i.e. index). Mirrors hr-shared.js applyLang so behaviour is identical. */
  function installI18n() {
    if (typeof window.__hrSetLang === 'function') return; // hr-shared owns it
    var I18N_RE = /[А-Яа-яЁё]/;
    function getLang() { try { return localStorage.getItem('hr-lang') || 'ru'; } catch (e) { return 'ru'; } }
    function applyLang(lang) {
      var T = window.HR_TRANS || {};
      $all('*').forEach(function (el) {
        if (el.children.length) return;
        var tag = el.tagName; if (tag === 'SCRIPT' || tag === 'STYLE' || tag === 'SVG' || tag === 'PATH') return;
        var ru = el.getAttribute && el.getAttribute('data-i18n-ru');
        if (ru === null || ru === undefined) {
          var cur = el.textContent;
          if (!cur || !I18N_RE.test(cur)) return;
          ru = cur.replace(/\s+/g, ' ').trim();
          try { el.setAttribute('data-i18n-ru', ru); el.setAttribute('data-i18n-o', cur); } catch (e) { return; }
        }
        if (lang === 'en') { var en = T[ru]; if (en != null && el.textContent !== en) el.textContent = en; }
        else { var o = el.getAttribute('data-i18n-o'); if (o != null && el.textContent !== o) el.textContent = o; }
      });
      try { document.documentElement.setAttribute('lang', lang === 'en' ? 'en' : 'ru'); } catch (e) {}
      $all('[data-hr-lang-btn]').forEach(function (b) { var on = b.getAttribute('data-hr-lang-btn') === lang; b.style.background = on ? '#FFFFFF1A' : 'transparent'; b.style.color = on ? '#F5F2EC' : '#8E8A9A'; });
    }
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
