/* HimRate landing — streamers page scripts (TASK-060). Externalized verbatim from
   the Pencil export streamers.html inline <script> blocks (CSP-safe; no inline scripts). */

window.HR = {
  root: '[data-pencil-name="Стримерам"]',
  accent: ["139,92,246","196,181,253"],
  mirage: true,
  logoScale: 0.19,
  assembleAts: [0.18, 0.5, 0.82],
  assembleWidth: 0.18
};



(function(){
  function q(n,r){ return (r||document).querySelector('[data-pencil-name="'+n+'"]'); }
  function qa(n,r){ return Array.prototype.slice.call((r||document).querySelectorAll('[data-pencil-name="'+n+'"]')); }
  function start(){ try{ run(); }catch(e){} }
  function run(){
    var ACCENT='#F9A8D4';

    /* keyframes for the auto-clip animations */
    var st=document.createElement('style');
    st.textContent='@keyframes hrEq{0%,100%{transform:scaleY(.22)}50%{transform:scaleY(1)}}@keyframes hrSweep{0%{transform:translateX(-130%)}100%{transform:translateX(380%)}}@keyframes hrPulse{0%{transform:scale(.55);opacity:.75}80%{opacity:0}100%{transform:scale(2.3);opacity:0}}';
    document.head.appendChild(st);

    var _watch=[];
    function tick(){ _watch.forEach(function(f){ try{ f(); }catch(e){} }); }
    window.addEventListener('resize', tick);
    document.addEventListener('scroll', tick, true);
    (function loop(){ tick(); requestAnimationFrame(loop); })();
    function onView(el, cb){ if(!el) return; var done=false;
      function chk(){ if(done) return; var r=el.getBoundingClientRect(), H=window.innerHeight||800; if(r.top<H*0.92 && r.bottom>0){ done=true; cb(); } }
      _watch.push(chk);
      if('IntersectionObserver' in window){ var io=new IntersectionObserver(function(es){ es.forEach(function(e){ if(e.isIntersecting){ io.disconnect(); if(!done){ done=true; cb(); } } }); },{threshold:0.15}); io.observe(el); }
      chk();
    }

    /* C8: remove the hero chips row */
    var chips=q('Chips'); if(chips) chips.style.display='none';

    /* remove the "Простыми словами" intro strip */
    var c0=q('C0 Простыми словами'); if(c0) c0.style.display='none';

    /* C9: logo accent -> page bottom-text colour (header + footer) */
    ['Logo','logo'].forEach(function(nm){ qa(nm).forEach(function(lg){
      Array.prototype.slice.call(lg.querySelectorAll('svg [fill]')).forEach(function(n){ var f=(n.getAttribute('fill')||'').toUpperCase(); if(f && f!=='#FFFFFF' && f!=='#FFF' && f!=='WHITE' && f!=='NONE'){ n.setAttribute('fill', ACCENT); } });
    }); });

    /* C7+0.1: Tile1 "Растекание" bars grow left->right, scrubbed by scroll */
    (function(){
      var tile=q('Tile1 Растекание'); if(!tile) return;
      var box=q('bars', tile); if(!box) return;
      var bars=qa('b', box); if(!bars.length) return;
      bars.forEach(function(b){ b.style.transformOrigin='left center'; b.style.transition='transform .12s linear'; });
      function frame(){ var H=window.innerHeight||800, r=tile.getBoundingClientRect();
        var p=Math.max(0,Math.min(1,(H*0.9 - r.top)/(H*0.55)));
        bars.forEach(function(b,i){ var l=Math.max(0,Math.min(1,(p - i*0.12)/0.45)), e=l*l*(3-2*l); b.style.transform='scaleX('+e.toFixed(3)+')'; });
      }
      _watch.push(frame); frame();
    })();

    /* C5: Tile3 "Ядро vs разброс" — split bar slides L<->R +/-30% on scroll */
    (function(){
      var tile=q('Tile3 Ядро'); if(!tile) return;
      var core=q('core',tile), scatter=q('scatter',tile);
      if(!core||!scatter) return;
      core.className=(core.className||'').replace(/w-\[\d+px\]/,''); scatter.className=(scatter.className||'').replace(/w-\[\d+px\]/,'');
      core.style.transition='width .15s linear'; scatter.style.transition='width .15s linear';
      var pcts=qa('pct',tile), legs=qa('t', q('legend',tile));
      var base=0.38;
      function frame(){
        var ph=(-tile.getBoundingClientRect().top)*0.011;
        var frac=Math.max(0.12,Math.min(0.66, base*(1+0.3*Math.sin(ph))));
        core.style.width=(frac*100).toFixed(1)+'%'; scatter.style.width=((1-frac)*100).toFixed(1)+'%';
        var a=Math.round(frac*100), b=100-a;
        if(pcts[0]) pcts[0].textContent=a+'%'; if(pcts[1]) pcts[1].textContent=b+'%';
        if(legs[0]) legs[0].textContent='Ядро '+a+'%'; if(legs[1]) legs[1].textContent='Разброс '+b+'%';
      }
      _watch.push(frame); frame();
    })();

    /* C6+0.4: Tile4 "Почему ушли" spark bars, scrubbed by scroll (drop bar pops) */
    (function(){
      var tile=q('Tile4 Почему'); if(!tile) return;
      var sp=q('spark', tile); if(!sp) return;
      var bars=qa('sb', sp); if(!bars.length) return;
      bars.forEach(function(b){ b.style.transformOrigin='center bottom'; b.style.transition='transform .12s linear'; });
      function frame(){ var H=window.innerHeight||800, r=tile.getBoundingClientRect();
        var p=Math.max(0,Math.min(1,(H*0.9 - r.top)/(H*0.55)));
        bars.forEach(function(b,i){ var l=Math.max(0,Math.min(1,(p - i*0.03)/0.4)), e=l*l*(3-2*l); b.style.transform='scaleY('+e.toFixed(3)+')'; });
      }
      _watch.push(frame); frame();
    })();

    /* C3: auto-clips — replace the static play icon with a lively animation (3 distinct) */
    (function(){
      var clips=q('clips'); if(!clips) return;
      var cards=Array.prototype.slice.call(clips.children).filter(function(c){ return q('ctr',c); });
      var eq=function(){ var s='<div style="display:flex;align-items:flex-end;gap:3px;height:34px">';
        var ds=[0,.14,.28,.18,.06]; for(var i=0;i<5;i++){ s+='<span style="display:block;width:4px;height:100%;background:#EC4899;border-radius:2px;transform-origin:bottom;animation:hrEq .9s ease-in-out infinite;animation-delay:'+ds[i]+'s"></span>'; } return s+'</div>'; };
      var sweep='<div style="position:relative;width:74%;height:6px;background:#FFFFFF14;border-radius:3px;overflow:hidden"><div style="position:absolute;top:0;left:0;width:30%;height:100%;background:linear-gradient(90deg,rgba(236,72,153,0),#EC4899,rgba(236,72,153,0));animation:hrSweep 1.5s linear infinite"></div></div>';
      var pulse='<div style="position:relative;width:30px;height:30px;display:flex;align-items:center;justify-content:center"><div style="position:absolute;inset:0;border:2px solid #EC4899;border-radius:50%;animation:hrPulse 1.7s ease-out infinite"></div><div style="position:absolute;inset:0;border:2px solid #EC4899;border-radius:50%;animation:hrPulse 1.7s ease-out infinite;animation-delay:.85s"></div><div style="width:9px;height:9px;background:#EC4899;border-radius:50%"></div></div>';
      var widgets=[eq(), sweep, pulse];
      cards.forEach(function(c,i){ var ctr=q('ctr',c); if(ctr){ ctr.innerHTML=widgets[i%3]; } });
    })();
  }
  if(document.readyState==='complete'||document.readyState==='interactive') setTimeout(start, 700);
  else window.addEventListener('DOMContentLoaded', function(){ setTimeout(start, 700); });
})();
