/* HimRate landing — viewers page scripts (TASK-060). Externalized verbatim from
   the Pencil export viewers.html inline <script> blocks (CSP-safe; no inline scripts). */

window.HR = {
  root: '[data-pencil-name="Зрителям"]',
  accent: ["52,211,153","110,231,183"],
  mirage: true,
  logoScale: 0.19,
  assembleAts: [0.18, 0.5, 0.82],
  assembleWidth: 0.18
};



(function(){
  function q(n,r){ return (r||document).querySelector('[data-pencil-name="'+n+'"]'); }
  function qa(n,r){ return Array.prototype.slice.call((r||document).querySelectorAll('[data-pencil-name="'+n+'"]')); }
  function start(){
    try{ run(); }catch(e){ /* no-op */ }
  }
  function run(){
    /* Desktop-only column height-equalisation: below lg the cards stack single
       column and responsive CSS owns the layout, so these inline-style hacks
       (height/alignItems/justify/minHeight) must NOT run — they fight the flow. */
    var DESK=(window.innerWidth||document.documentElement.clientWidth||0)>=1024;
    /* ---- C11: remove the whole message-feed row (ЛЕНТА СООБЩЕНИЙ) ---- */
    var r3=q('Row 3'); if(r3 && /ЛЕНТА СООБЩЕНИЙ/i.test(r3.textContent||'')) r3.style.display='none';

    /* ---- C15: the top "Простыми словами" strip reads awkwardly at the very top — drop it below the hero ---- */
    var z0=q('З0 Простыми словами'), hero=q('З1 Hero');
    if(z0 && hero && hero.parentElement){
      hero.parentElement.insertBefore(z0, hero.nextSibling);
      z0.style.borderTop='1px solid #FFFFFF14';
    }

    /* ---- C14 + C9 + C12: equalise card heights so columns line up (no stray empty space, no overhang) ---- */
    function stretchRow(row){
      if(!row) return; row.style.alignItems='stretch';
      Array.prototype.slice.call(row.children).forEach(function(c){
        c.style.height='auto'; c.style.alignSelf='stretch';
        if(/flex-col/.test(c.className||'')) c.style.justifyContent='space-between';
      });
    }
    /* Row 1 (Hours / Top-channels / Games): revert the earlier height-stretch — cards size to content (ccf4f656ca) */
    if(DESK){
    stretchRow(q('Row 2'));
    var ai=q('AI-пересказ');
    if(ai){
      var right=ai.parentElement; if(right) right.style.justifyContent='space-between';
      var aiRow=right&&right.parentElement; stretchRow(aiRow);
      ai.style.flex='1 1 auto';
      var mem=q('Воспоминание'); if(mem) mem.style.flex='1 1 auto';
    }
    var dev=q('Device'); if(dev){ var devRow=dev.parentElement&&dev.parentElement.parentElement; stretchRow(dev.parentElement); stretchRow(devRow); }

    /* ---- 88305e3cb0: "Раид" is much shorter than the metric block beside it — stretch it to match ---- */
    var raid=q('Raid'); if(raid && raid.parentElement){
      raid.parentElement.style.alignItems='stretch';
      raid.style.height='auto'; raid.style.alignSelf='stretch';
      raid.style.justifyContent='space-between';
    }

    /* ---- 7c65f1e307 + 984f245d41: level the "Куда пойти" (left) and the right column so their bottoms align ---- */
    var kuda=q('Куда пойти'); var grid=kuda&&kuda.parentElement;
    var rightCol=null;
    if(grid){
      grid.style.alignItems='stretch';
      /* the right column is Куда пойти's DIRECT sibling in the grid (not a nested "Right") */
      Array.prototype.slice.call(grid.children).forEach(function(c){ if(c!==kuda) rightCol=rightCol||c; });
      if(rightCol){
        rightCol.style.justifyContent='space-between';
        var pereh=q('Переход', rightCol); if(pereh){ pereh.style.flex='1 1 auto'; }
      }
    }

    /* ---- 4583bac6bf: align the "Реальные зрители" number column to the left ---- */
    qa('c_v').forEach(function(c){ c.style.justifyContent='flex-start'; });
    var hreal=q('h_РЕАЛЬНЫЕ'); if(hreal) hreal.style.justifyContent='flex-start';
    /* ---- 1752f7290c: centre the "Надёжность" number column ---- */
    qa('c_r').forEach(function(c){ c.style.justifyContent='center'; });
    var hrel=q('h_НАДЁЖНОСТЬ'); if(hrel) hrel.style.justifyContent='center';
    } /* end DESK equalisation */

    /* ---- c58f4f9a1c: theme the header + footer logo to this page's accent (violet), not the teal main-page colour ---- */
    var THEME='#A855F7';
    qa('Wordmark').forEach(function(wm){
      Array.prototype.slice.call(wm.querySelectorAll('[fill="#22D3EE"]')).forEach(function(n){ n.setAttribute('fill', THEME); });
    });

    /* ---- d64021b057: drop the three "proof" check-chips from the hero ---- */
    var proofs=q('Proofs'); if(proofs) proofs.style.display='none';

    /* ---- C1/C2: hero headline lines rise in on load, staggered ---- */
    if(hero){ var hl=q('Headline', hero);
      if(hl){ var lines=Array.prototype.slice.call(hl.children);
        lines.forEach(function(ln,i){ ln.setAttribute('data-hrz-head',''); ln.style.animationDelay=(0.08+i*0.12)+'s'; });
        requestAnimationFrame(function(){ lines.forEach(function(ln){ ln.classList.add('hrz-go'); }); });
        /* fail-safe: never let the hero headline stay invisible if the animation doesn't advance */
        setTimeout(function(){ lines.forEach(function(ln){ ln.classList.add('hrz-shown'); }); }, 1400);
      }
    }

    /* ---- 6eebc5a9f9 + 54f5a4b1ce + 043e5c42aa: scroll-triggered animations ----
       Triggered three ways for reliability: IntersectionObserver, scroll listener, and a short poll. */
    var _watch=[];
    function onView(el, cb){
      if(!el) return; var done=false;
      function fire(){ if(done) return; done=true; cb(el); }
      function check(){ if(done) return; var r=el.getBoundingClientRect(); var vh=window.innerHeight||document.documentElement.clientHeight;
        if(r.top < vh*0.9 && r.bottom > 0){ fire(); } }
      _watch.push(check);
      if('IntersectionObserver' in window){
        var io=new IntersectionObserver(function(ents){ ents.forEach(function(en){ if(en.isIntersecting){ io.disconnect(); fire(); } }); }, {threshold:0.12, rootMargin:'0px 0px -8% 0px'});
        io.observe(el);
      }
      check();
    }
    // 6930910461: activity heat-map — squares fill in a diagonal wave, scrubbed by scroll
    (function(){
      var rows=qa('cells').filter(function(c){ return c.children.length>=8; });
      if(!rows.length) return;
      var cont=(rows[0].parentElement&&rows[0].parentElement.parentElement)||rows[0];
      var cells=[], maxC=0;
      rows.forEach(function(row,r){
        Array.prototype.slice.call(row.children).forEach(function(el,c){
          var m=(el.className||'').match(/A855F7([0-9a-fA-F]{2})/);
          var a=m?parseInt(m[1],16)/255:0.5;
          el.style.transition='background-color .25s linear, transform .22s ease';
          el.style.transformOrigin='center';
          el.style.background='rgba(168,85,247,0)';
          el.style.transform='scale(.5)';
          cells.push({el:el,a:a,d:r+c});
          if(c>maxC) maxC=c;
        });
      });
      var maxD=(rows.length-1)+maxC, spread=7;
      function frame(){
        var H=window.innerHeight||800, rc=cont.getBoundingClientRect();
        var p=Math.max(0,Math.min(1,(H*0.82-rc.top)/(H*0.55)));
        var wave=p*(maxD+spread);
        cells.forEach(function(o){
          var t=Math.max(0,Math.min(1,(wave-o.d)/spread)), e=t*t*(3-2*t);
          o.el.style.background='rgba(168,85,247,'+(o.a*e).toFixed(3)+')';
          o.el.style.transform='scale('+(0.5+0.5*e).toFixed(3)+')';
        });
      }
      _watch.push(frame); frame();
    })();
    // 1e68262b6f: auto-insight weekday bars sweep, active column + % (35→65) change, scrubbed by scroll
    (function(){
      var wd=q('Weekday'); if(!wd) return;
      var card=wd.parentElement;
      var cols=Array.prototype.slice.call(wd.children);
      var bars=cols.map(function(c){ return q('bar',c)||c.querySelector('div'); });
      var labs=cols.map(function(c){ return q('t',c); });
      var big=q('big',card), vlab=q('v',card);
      if(big) big.setAttribute('data-hr-skip','1');
      var gen=['понедельника','вторника','среды','четверга','пятницы','субботы','воскресенья'];
      bars.forEach(function(b){ if(b){ b.style.transition='height .3s cubic-bezier(.2,.7,.2,1), background-color .3s ease'; b.style.willChange='height'; } });
      var n=cols.length-1;
      function frame(){
        var H=window.innerHeight||800, rc=card.getBoundingClientRect();
        var p=Math.max(0,Math.min(1,(H*0.82-rc.top)/(H*0.55)));
        var peak=p*n, active=Math.max(0,Math.min(n,Math.round(peak)));
        bars.forEach(function(b,i){ if(!b) return;
          var dist=i-peak, g=Math.exp(-(dist*dist)/(2*0.85*0.85));
          b.style.height=Math.round(40+86*(0.22+0.78*g))+'px';
          b.style.background=(i===active)?'#A855F7':'#FFFFFF12';
        });
        labs.forEach(function(l,i){ if(l) l.style.color=(i===active)?'#C4B5FD':'#8E8A9A'; });
        if(big) big.textContent=Math.round(35+30*p)+'%';
        if(vlab) vlab.textContent='вечерний зритель '+gen[active];
      }
      _watch.push(frame); frame();
    })();
    // 043e5c42aa: real-viewers counter scrubbed 500 → 4500 on scroll (like the home hero)
    (function(){
      var bignum=document.querySelector('[data-comment-anchor="043e5c42aa-div"]'); if(!bignum) return;
      var card=bignum.closest('[data-pencil-name="Big Metric"]')||(bignum.parentElement&&bignum.parentElement.parentElement); if(!card) return;
      var fill=q('fill',card), track=q('track',card);
      var pct=qa('a',card).filter(function(e){ return /живая аудитория/.test(e.textContent||''); })[0];
      if(fill){ fill.className=(fill.className||'').replace(/w-\[\d+(?:\.\d+)?px\]/,''); fill.style.minWidth='0'; fill.style.transition='width .15s linear'; }
      // 9cdd78a690: threshold pills change with the number (small→значительная, mid→аномалия, 4000+→реальная)
      var thr=q('thresholds',card), pills=[];
      if(thr){ qa('pill',thr).forEach(function(pl){
        var t=q('t',pl), tx=(t&&t.textContent||'');
        var col=/Значительная/.test(tx)?'#F87171':/Аномалия/.test(tx)?'#FBBF24':'#34D399';
        pl.style.transition='background-color .25s ease, border-color .25s ease';
        if(t) t.style.transition='color .25s ease';
        pills.push({pl:pl,t:t,col:col,tx:tx});
      }); }
      function setPills(v){
        var act=v<2000?'red':v<4000?'yel':'grn';
        pills.forEach(function(o){
          var k=/Значительная/.test(o.tx)?'red':/Аномалия/.test(o.tx)?'yel':'grn';
          if(k===act){ o.pl.style.background=o.col+'15'; o.pl.style.border='1px solid '+o.col+'3D'; if(o.t) o.t.style.color=o.col; }
          else { o.pl.style.background='#FFFFFF06'; o.pl.style.border='1px solid #FFFFFF14'; if(o.t) o.t.style.color='#A7A3B0'; }
        });
      }
      function nb(n){ n=Math.round(n); var s=String(n),o='',c=0; for(var i=s.length-1;i>=0;i--){ o=s[i]+o; if(++c%3===0&&i>0) o=' '+o; } return o; }
      function frame(){
        var H=window.innerHeight||800, rc=card.getBoundingClientRect();
        var p=Math.max(0,Math.min(1,(H*0.85-rc.top)/(H*0.6)));
        var v=Math.round(500+(4500-500)*p), pc=Math.round(v/5000*100);
        bignum.textContent=nb(v);
        if(track&&fill){ var tw=track.getBoundingClientRect().width; if(tw>0) fill.style.width=Math.round(tw*v/5000)+'px'; }
        if(pct) pct.textContent=pc+'% — живая аудитория';
        setPills(v);
      }
      _watch.push(frame); frame();
    })();
    // count up standalone percentage values when their section scrolls into view
    Array.prototype.slice.call(document.querySelectorAll('[data-pencil-name="Зрителям Top"] div, [data-pencil-name="Зрителям Bottom"] div')).forEach(function(el){
      if(el.getAttribute('data-hr-skip')) return;
      if(el.children.length) return; var tx=(el.textContent||'').trim();
      if(!/^\d{1,3}%$/.test(tx)) return; var to=parseInt(tx,10); if(to<5) return;
      el.__pTo=to;
      onView(el, function(){ var st=Date.now(); var iv=setInterval(function(){ var p=Math.min(1,(Date.now()-st)/900), e=1-Math.pow(1-p,3); el.textContent=Math.round(to*e)+'%'; if(p>=1) clearInterval(iv); }, 16); });
    });

    /* drive all scroll-reveals from real scroll events (reliable across environments) */
    var tick=function(){ _watch.forEach(function(f){ f(); }); };
    window.addEventListener('scroll', tick, {passive:true});
    window.addEventListener('resize', tick);
    document.addEventListener('scroll', tick, {passive:true});
    /* short poll so a missed scroll event can't leave a section stuck hidden */
    var polls=0, pollIv=setInterval(function(){ tick(); if(++polls>40) clearInterval(pollIv); }, 250);

    /* re-level the "Куда пойти" / right column after async content settles */
    function syncLevel(){ if(!kuda||!rightCol) return; var rh=Math.round(rightCol.getBoundingClientRect().height); if(rh>0) kuda.style.minHeight=rh+'px'; }
    syncLevel(); setTimeout(syncLevel, 600); setTimeout(syncLevel, 1500);
    window.addEventListener('resize', syncLevel);
    window.addEventListener('load', syncLevel);
  }
  if(document.readyState==='complete'||document.readyState==='interactive') setTimeout(start, 700);
  else window.addEventListener('DOMContentLoaded', function(){ setTimeout(start, 700); });
})();
