/* HimRate landing — methodology page scripts (TASK-060). Externalized verbatim from
   the Pencil export methodology.html inline <script> blocks (CSP-safe; no inline scripts). */

window.HR = {
  root: '[data-pencil-name="Методология"]',
  accent: ["99,102,241","129,140,248"],
  mirage: true,
  logoScale: 0.19,
  assembleAts: [0.18, 0.5, 0.82],
  assembleWidth: 0.18
};



(function(){
  var ACCENT='#67E8F9';
  function go(){ try{ Array.prototype.slice.call(document.querySelectorAll('[data-pencil-name="Wordmark"] svg [fill]')).forEach(function(n){ var f=(n.getAttribute('fill')||'').toUpperCase(); if(f && f!=='#FFFFFF' && f!=='#FFF' && f!=='WHITE' && f!=='NONE'){ n.setAttribute('fill', ACCENT); } }); }catch(e){} }
  if(document.readyState!=='loading'){ setTimeout(go,800); setTimeout(go,1600); } else window.addEventListener('DOMContentLoaded', function(){ setTimeout(go,800); setTimeout(go,1600); });
})();
