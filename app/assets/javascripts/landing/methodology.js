/* HimRate landing — methodology page scripts (TASK-060, Export 3 clean). Externalised
   verbatim from methodology.html inline <script> blocks (incl. responsive burger); routes
   patched; CSP-safe. */

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



/* Mobile burger for 05-metodologiya — activates ≤1024 via CSS. Reuses hr-shared nav + lang. */
(function(){
  function build(){
    var hdr=document.querySelector('[data-pencil-name="Header"]'); if(!hdr||document.querySelector('.hr-burger')) return;
    var b=document.createElement('div'); b.className='hr-burger'; b.setAttribute('aria-label','Меню'); b.innerHTML='<span></span><span></span><span></span>';
    hdr.appendChild(b);
    var nav=document.createElement('nav'); nav.className='hr-mnav';
    var links=[['Главная','/'],['Стримерам','/streamers'],['Брендам','/brands'],['Зрителям','/viewers'],['Методология и цены','/methodology']];
    nav.innerHTML=links.map(function(l){return '<a href="'+l[1]+'">'+l[0]+'<span>&rarr;</span></a>';}).join('')
      +'<a class="cta" href="methodology.html">Подключить канал</a>'
      +'<div class="hr-mlang"><button data-l="ru">RU</button><button data-l="en">EN</button></div>';
    document.body.appendChild(nav);
    function set(o){ nav.classList.toggle('open',o); b.classList.toggle('x',o); document.body.style.overflow=o?'hidden':''; }
    var open=false; b.addEventListener('click',function(){ open=!open; set(open); });
    nav.querySelectorAll('a').forEach(function(a){ a.addEventListener('click',function(){ open=false; set(false); }); });
    nav.querySelectorAll('.hr-mlang button').forEach(function(bt){ bt.addEventListener('click', function(){ if(window.__hrSetLang) window.__hrSetLang(bt.getAttribute('data-l')); }); });
  }
  if(document.readyState!=='loading') setTimeout(build,600); else window.addEventListener('DOMContentLoaded',function(){ setTimeout(build,600); });
})();
