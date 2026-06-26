/* HimRate landing — brands page scripts (TASK-060). Externalized verbatim from
   the Pencil export brands.html inline <script> blocks (CSP-safe; no inline scripts). */

window.HR = {
  root: '[data-pencil-name="Брендам"]',
  accent: ["34,211,238","103,232,249"],
  mirage: true,
  logoScale: 0.19,
  assembleAts: [0.18, 0.5, 0.82],
  assembleWidth: 0.18
};



(function(){
  function q(n){ return document.querySelector('[data-pencil-name="'+n+'"]'); }
  function start(){ try{ run(); }catch(e){} }
  function run(){
    /* Desktop-only height-equalisation (below lg cards stack; CSS owns layout). */
    var DESK=(window.innerWidth||document.documentElement.clientWidth||0)>=1024;
    /* ---- C5: drop the top "Простыми словами — для бренда" strip (redundant with the hero) ----
       This also makes "Б2 Проверка" the 2nd block, right after the hero (C3). ---- */
    var b0=q('Б0 Простыми словами'); if(b0) b0.style.display='none';

    /* ---- C6 + C7: trim the empty space under the Meter / Checks panels ---- */
    var row=q('Б2 Проверка') && q('Б2 Проверка').querySelector('[data-pencil-name="Row"]');
    if(DESK && row){
      row.className=(row.className||'').replace(/h-\[\d+px\]/,'');
      row.style.height='auto'; row.style.alignItems='stretch';
      Array.prototype.slice.call(row.children).forEach(function(c){
        c.className=(c.className||'').replace(/h-full/,''); c.style.height='auto'; c.style.alignSelf='stretch';
      });
    }

    /* ===== Himych review: scroll animations, accent + content ===== */
    function q1(n,r){ return (r||document).querySelector('[data-pencil-name="'+n+'"]'); }
    function qa(n,r){ return Array.prototype.slice.call((r||document).querySelectorAll('[data-pencil-name="'+n+'"]')); }
    function nbsp(v){ v=Math.round(v); var s=String(Math.abs(v)),o='',c=0; for(var i=s.length-1;i>=0;i--){ o=s[i]+o; if(++c%3===0&&i>0) o=' '+o; } return (v<0?'-':'')+o; }
    var _watch=[];
    function tick(){ _watch.forEach(function(f){ try{ f(); }catch(e){} }); }
    window.addEventListener('resize', tick);
    document.addEventListener('scroll', tick, true);
    (function loop(){ tick(); requestAnimationFrame(loop); })();
    function onView(el, cb){ if(!el) return; var done=false;
      function chk(){ if(done) return; var r=el.getBoundingClientRect(), H=window.innerHeight||800; if(r.top<H*0.9 && r.bottom>0){ done=true; cb(); } }
      _watch.push(chk);
      if('IntersectionObserver' in window){ var io=new IntersectionObserver(function(es){ es.forEach(function(e){ if(e.isIntersecting){ io.disconnect(); if(!done){ done=true; cb(); } } }); },{threshold:0.15}); io.observe(el); }
      chk();
    }

    /* C7: header logo accent -> page cyan (#67E8F9, the "Узнайте, что сработало" hex) */
    var _logo=q1('Logo'); if(_logo){ Array.prototype.slice.call(_logo.querySelectorAll('[fill="#6366F1"]')).forEach(function(n){ n.setAttribute('fill','#67E8F9'); }); }

    /* C1: remove the honesty plashka inside the media block */
    var _b6=q1('Б6 Медиа'); if(_b6){ Array.prototype.slice.call(_b6.children).forEach(function(ch){ if(/\bflex-row\b/.test(ch.className||'')) ch.style.display='none'; }); }

    /* C8: Meter — classic scroll counter; bar fills, verdict text changes with the number */
    (function(){
      var m=q1('Meter'); if(!m) return;
      var big=q1('big',m), track=q1('track',m), bar=q1('bar',m), badge=q1('badge',m);
      var dot=badge&&q1('d',badge), btxt=badge&&q1('t',badge);
      var CCV=5000, TO=4200;
      if(big) big.__cu=1;
      if(bar){ bar.className=(bar.className||'').replace(/w-\[\d+(?:\.\d+)?px\]/,''); bar.style.minWidth='0'; bar.style.transition='width .15s linear, background-color .25s ease'; }
      function frame(){
        var H=window.innerHeight||800, rc=m.getBoundingClientRect();
        var p=Math.max(0,Math.min(1,(H*0.85-rc.top)/(H*0.6)));
        var v=Math.round(600+(TO-600)*p), pct=v/CCV;
        if(big) big.textContent=nbsp(v);
        if(track&&bar){ var tw=track.getBoundingClientRect().width; if(tw>0) bar.style.width=Math.round(tw*pct)+'px'; }
        var col,bg,tcol,label;
        var _en=(function(){ try{ return (localStorage.getItem('hr-lang')||'ru')==='en'; }catch(e){ return false; } })();
        if(pct>=0.7){ col='#34D399'; bg='#10B98122'; tcol='#6EE7B7'; label=_en?'REAL AUDIENCE':'АУДИТОРИЯ РЕАЛЬНАЯ'; }
        else if(pct>=0.4){ col='#FBBF24'; bg='#FBBF2422'; tcol='#FCD34D'; label=_en?'VIEWER ANOMALY':'АНОМАЛИЯ ОНЛАЙНА'; }
        else { col='#F87171'; bg='#F8717122'; tcol='#FCA5A5'; label=_en?'SIGNIFICANT ANOMALY':'ЗНАЧИТЕЛЬНАЯ АНОМАЛИЯ'; }
        if(bar) bar.style.background=col;
        if(badge) badge.style.background=bg;
        if(dot) dot.style.background=col;
        if(btxt){ btxt.style.color=tcol; btxt.textContent=label+' · '+Math.round(pct*100)+'%'; }
      }
      _watch.push(frame); frame();
    })();

    /* C5: spike chart — constant loop; blue spike sweeps, peak height + "+47" vary each beat */
    (function(){
      var sc=q1('Spike Chart'); if(!sc) return;
      var bars=qa('b', sc); if(!bars.length) return;
      var plus=q1('plus', sc); if(plus) plus.__cu=1;   // take over from the shared count-up
      var n=bars.length, maxH=132, minH=18;
      bars.forEach(function(b){ b.className=(b.className||'').replace(/h-\[\d+(?:\.\d+)?px\]/,''); b.style.transition='height .5s cubic-bezier(.2,.8,.2,1), background-color .5s ease'; });
      var t0=Date.now(), lastAct=-1, peakH=124;
      function step(){
        var t=(Date.now()-t0)/1000;
        var act=Math.floor(t/0.85)%n;            // highlight jumps to a new bar ~every 0.85s
        if(act!==lastAct){
          lastAct=act;
          var r=Math.abs(Math.sin(act*1.7+0.6));   // 0..1, different per bar
          peakH=Math.round(92+46*r);               // 92..138 — never the same size
          if(plus) plus.textContent='+'+Math.round(32+31*r);   // new number exactly when the bar switches
        }
        for(var i=0;i<n;i++){
          var b=bars[i], d=Math.abs(i-act), col='#2A2740', h;
          var breathe=Math.max(0,Math.min(1, 0.34 + 0.2*Math.sin(t*2.1 + i*0.8)));
          if(d===0){ h=peakH; col='#22D3EE'; }
          else if(d===1){ h=Math.max(minH+(maxH-minH)*breathe, peakH*0.55); col='#22D3EE5C'; }
          else if(d===2){ h=minH+(maxH-minH)*Math.max(0.46,breathe); col='#3A2F50'; }
          else { h=minH+(maxH-minH)*breathe; }
          b.style.height=Math.round(h)+'px';
          b.style.background=col;
        }
      }
      if(sc.__spikeIv) clearInterval(sc.__spikeIv);
      sc.__spikeIv=setInterval(step, 130); step();
    })();

    /* C2: media platform numbers drift +/-30% on scroll */
    (function(){
      var b6=q1('Б6 Медиа'); if(!b6) return;
      var items=qa('v', b6).filter(function(e){ return /K/i.test(e.textContent||''); }).map(function(e,i){
        var tx=(e.textContent||'').trim(); var dec=/,/.test(tx);
        var base=parseFloat(tx.replace(/[^\d.,]/g,'').replace(',','.'))||0;
        e.style.transition='color .2s ease';
        return {el:e, base:base, dec:dec, ph:i*1.7};
      });
      function fmt(v,dec){ return dec ? (Math.round(v*10)/10).toFixed(1).replace('.',',')+'K' : Math.round(v)+'K'; }
      function frame(){ var ph=(-b6.getBoundingClientRect().top)*0.012; items.forEach(function(o){ o.el.textContent=fmt(o.base*(1+0.3*Math.sin(ph+o.ph)), o.dec); }); }
      _watch.push(frame); frame();
    })();

    /* C3: stretch the cabinet CTA to fill the empty space beside the tall filters */
    (function(){
      var ex=q1('Exchange Row'); if(!ex||!DESK) return;
      ex.style.alignItems='stretch';
      var res=q1('Results', ex), cab=q1('Cabinet CTA', ex);
      if(res){ res.className=(res.className||'').replace(/h-fit/,''); res.style.height='auto'; res.style.alignSelf='stretch'; }
      if(cab){ cab.style.flex='1 1 auto'; }
    })();
  }
  if(document.readyState==='complete'||document.readyState==='interactive') setTimeout(start, 700);
  else window.addEventListener('DOMContentLoaded', function(){ setTimeout(start, 700); });
})();
