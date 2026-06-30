/* HimRate — shared mobile behaviour. Auto-inits from elements present on the page.
   Load AFTER hr-i18n.js. Everything is progressive: content shows even if JS fails. */
(function(){
  /* Mobile layer only — the desktop layer (hidden lg:block) has its own canvas/JS.
     Below lg this runs; at/above lg the mobile .app is display:none, so bail to
     avoid a second background canvas + wasted animation loops. */
  if ((window.innerWidth || document.documentElement.clientWidth || 0) >= 1024) return;
  function $(s,r){ return (r||document).querySelector(s); }
  function $all(s,r){ return [].slice.call((r||document).querySelectorAll(s)); }

  /* inject HimRate wordmark into every empty .logo (mark tinted with --accent2) */
  (function(){
    var acc=(getComputedStyle(document.documentElement).getPropertyValue('--accent2')||'#22D3EE').trim();
    var marks='m48.8 35-1.5-4.1c-1-2.4-4.5-7.9-7.6-10.3-1.8-1.5-3.6-1.9-5.8-1.7-6.2 0.6-7.6 8.5-8.2 16h23.1v0.1z|m29.3 4.1-0.4-2.5-2.5 0.4 0.4 2.4c-3 0.6-5.4 3.3-5.4 6.8 0 4 3.1 7.6 7.2 7.6s7.1-3.2 7.1-7.5c0-3.5-2.8-7.1-6.4-7.2zm0 9.9c-1.4 0-3-1.4-3-3.1 0-1 0.6-2 1.5-2.5l-0.9-4 2.4-0.2 0.5 4.1c1.4 0.1 2.6 1.3 2.6 2.6 0 1.5-1.4 3.1-3.1 3.1z|m17.8 29.8c-2.1 0-4.1 1.4-4.9 3.4h-8c-1.9 0.2-1.3-1.6-1-2.5l4-10.7c0.5-1.4 1.3-2.4 1.6-1.2 1 3.8 3 9.8 3.1 9.9l2-0.5-4.6-23.7-2 0.5c-0.1 0-0.1 6.8 0.8 11.4-1.4 0.7-2.2 2.1-2.9 3.9l-3 7.9c-0.6 2-1.9 5-0.3 6.2 0.5 0.4 1 0.6 2 0.6h18.1c0-2.7-2-5.2-4.9-5.2z'.split('|');
    var letters=['m64.4 2.8h-6.7v31.8h6.7v-12.7h3.6v12.8l6.4-0.1v-31.8h-6.4v13.5h-3.6v-13.5z','m77.1 2.8h6.3v31.8h-6.3v-31.8z','m86.2 2.8h6.2l3.6 13.7 3.9-13.7h6.6v31.8h-6.1v-15.5l-4.4 12.9-4-12.8v15.4h-5.8v-31.8z','m122.7 2.8h-13.4v31.8h6.3v-10.1h0.9l3.1 10.1h6.5l-3.4-10c2.1 0.3 3-1.1 3-3v-15.2c0-2.9-2.1-3.6-3-3.6zm-3.3 16.8h-3.7v-11.3h3.1c0.7 0 0.7 0.5 0.7 1.2v9.3c0 0.5 0 0.8-0.1 0.8z','m140 2.8h-6.3l-6.3 31.8h6.6l0.6-4h4.3l0.6 4h6.3l-5.8-31.8zm-4.7 23.1 1.5-11.2 1.5 11.2h-3z','m146 2.8-1.8 5.9h4.4v26h6.9v-26h4l-1.5-5.9h-12z','m161.4 2.8h11.5l1.2 5.9h-6.7v7.6h5.1v5.6h-5.1v6.8h6.5l-1.2 5.9h-11.3l-0.1-0.1 0.1-31.7z'];
    var svg='<svg viewBox="0 -9 176.3 53.9" xmlns="http://www.w3.org/2000/svg" role="img" aria-label="HimRate">';
    letters.forEach(function(d){ svg+='<path fill="#fff" d="'+d+'"/>'; });
    svg+='<rect fill="'+acc+'" x="2.3" y="39.7" width="171.8" height="3.1"/>';
    marks.forEach(function(d){ svg+='<path fill="'+acc+'" d="'+d+'"/>'; });
    svg+='<circle cx="80.25" cy="-2.8" r="3.6" fill="'+acc+'"/></svg>';
    $all('.logo').forEach(function(l){ if(!l.querySelector('svg')) l.innerHTML=svg; });
  })();

  /* burger menu */
  var burger=$('#burger'), nav=$('#nav');
  if(burger&&nav){
    burger.addEventListener('click', function(){ var o=nav.classList.toggle('open'); burger.classList.toggle('x',o); document.body.style.overflow=o?'hidden':''; });
    $all('a',nav).forEach(function(a){ a.addEventListener('click', function(){ nav.classList.remove('open'); burger.classList.remove('x'); document.body.style.overflow=''; }); });
  }

  /* RU/EN (reuses hr-i18n.js) */
  var lang=$('#lang');
  if(lang){
    function setUI(l){ $all('button',lang).forEach(function(b){ b.classList.toggle('on', b.getAttribute('data-l')===l); }); }
    $all('button',lang).forEach(function(b){ b.addEventListener('click', function(){ var l=b.getAttribute('data-l'); setUI(l); if(window.__hrSetLang) window.__hrSetLang(l); }); });
    try{ setUI(localStorage.getItem('hr-lang')||'ru'); }catch(e){}
  }

  /* robust RU/EN: translate at the TEXT-NODE level so mixed-content elements
     (price + <small>, FAQ question + icon, nav + arrow, value + <br>) also switch. */
  (function(){
    function tx(lang){
      var T=window.HR_TRANS||{}; if(!document.body) return;
      var w=document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, null), n, nodes=[];
      while(n=w.nextNode()) nodes.push(n);
      nodes.forEach(function(tn){
        var par=tn.parentNode; if(!par) return; var pn=par.nodeName;
        if(pn==='SCRIPT'||pn==='STYLE'||pn==='TEXTAREA') return;
        var raw=tn.nodeValue, key=raw.replace(/\s+/g,' ').trim(); if(!key) return;
        if(tn.__ru===undefined){ if(!/[А-Яа-яЁё]/.test(key)) return; tn.__ru=key; tn.__orig=raw; }
        if(lang==='en'){ var en=T[tn.__ru]; if(en!=null){ var l=raw.match(/^\s*/)[0], t=raw.match(/\s*$/)[0]; tn.nodeValue=l+en+t; } }
        else if(tn.__orig!=null){ tn.nodeValue=tn.__orig; }
      });
      try{ document.documentElement.setAttribute('lang', lang==='en'?'en':'ru'); }catch(e){}
      $all('[data-hr-lang-btn],#lang button').forEach(function(b){ var v=b.getAttribute('data-hr-lang-btn')||b.getAttribute('data-l'); b.classList.toggle('on', v===lang); });
    }
    // our translator is the single authority on mobile (overrides hr-i18n's leaf-only one)
    window.__hrSetLang=function(l){ l=(l==='en')?'en':'ru'; try{ localStorage.setItem('hr-lang',l); }catch(e){} tx(l); };
    var cur=(function(){ try{ return localStorage.getItem('hr-lang')||'ru'; }catch(e){ return 'ru'; } })();
    setTimeout(function(){ tx(cur); }, 300);
    setTimeout(function(){ tx(cur); }, 1200);
  })();

  /* platforms marquee (data-marquee holds JSON [["name","#color"],...]) */
  $all('[data-marquee]').forEach(function(tr){
    try{ var items=JSON.parse(tr.getAttribute('data-marquee'));
      function chip(p){ return '<div class="chip"><span class="nm">'+p[0]+'</span><span class="st" style="background:'+p[1]+'"></span></div>'; }
      tr.innerHTML=(items.map(chip).join('')).repeat(2);
    }catch(e){}
  });

  /* spike chart loop (#spikeBars + #spikePlus) */
  (function(){
    var box=$('#spikeBars'), plus=$('#spikePlus'); if(!box) return;
    var N=22; for(var i=0;i<N;i++) box.insertAdjacentHTML('beforeend','<div class="b"></div>');
    var bars=$all('.b',box), t0=Date.now(), last=-1, peak=0.7, acc=getComputedStyle(document.documentElement).getPropertyValue('--accent2').trim()||'#22D3EE';
    function step(){ var t=(Date.now()-t0)/1000, act=Math.floor(t/0.85)%N;
      if(act!==last){ last=act; var r=Math.abs(Math.sin(act*1.7+0.6)); peak=0.62+0.38*r; if(plus) plus.textContent='+'+Math.round(32+31*r); }
      for(var i=0;i<N;i++){ var d=Math.abs(i-act), br=Math.max(0,Math.min(1,0.34+0.2*Math.sin(t*2.1+i*0.8))), h, col='#2A2740';
        if(d===0){ h=peak; col=acc; } else if(d===1){ h=Math.max(br,peak*0.55); col='rgba(255,255,255,.18)'; } else if(d===2){ h=Math.max(0.46,br); col='#3A2F50'; } else { h=br; }
        var hv=Math.max(0,Math.min(1,h)); bars[i].style.height=(14+86*hv).toFixed(1)+'%'; bars[i].style.background=col; }
    }
    setInterval(step,130); step();
  })();

  /* reveal + count-up + fills — driven by a rAF loop so it ALWAYS fires
     (independent of IntersectionObserver / scroll-event quirks). */
  function nbsp(n){ var s=String(Math.round(n)),o='',c=0; for(var i=s.length-1;i>=0;i--){ o=s[i]+o; if(++c%3===0&&i>0)o='\u202F'+o; } return o; }
  function countUp(el){ if(el.__d) return; el.__d=1; var to=+el.getAttribute('data-count'), st=Date.now(), dur=1200;
    var iv=setInterval(function(){ var p=Math.min(1,(Date.now()-st)/dur), e=1-Math.pow(1-p,3); el.textContent=nbsp(to*e); if(p>=1) clearInterval(iv); },16); }
  function revealEl(t){ if(t.__r) return; t.__r=1; t.classList.add('in');
    $all('[data-count]',t).forEach(countUp);
    $all('[data-fill]',t).forEach(function(f){ f.style.width=f.getAttribute('data-fill')+'%'; });
  }
  var targets=$all('.reveal,.hero,.meter,.final');
  (function watch(){
    var H=window.innerHeight||800, left=false;
    for(var i=0;i<targets.length;i++){ var s=targets[i]; if(s.__r) continue; left=true;
      var r=s.getBoundingClientRect(); if(r.top < H*0.86 && r.bottom > 0) revealEl(s); }
    requestAnimationFrame(watch); // keep watching so every block animates in as it scrolls into view
  })();

  /* faq accordion */
  $all('.qa .q').forEach(function(q){ q.addEventListener('click', function(){
    var qa=q.parentElement, a=$('.a',qa), open=qa.classList.contains('open');
    $all('.qa').forEach(function(o){ o.classList.remove('open'); $('.a',o).style.maxHeight=null; });
    if(!open){ qa.classList.add('open'); a.style.maxHeight=a.scrollHeight+'px'; }
  }); });

  /* animated dot background — scroll-driven assembly (dots gather into the wordmark
     at scroll peaks, then disperse), mirroring the desktop background. */
  (function(){
    var cv=$('#bgfx canvas'); if(!cv) return; var ctx=cv.getContext('2d');
    var W,H,DPR,dots=[],free=[],targets=[],N=0;
    var rgb=(getComputedStyle(document.documentElement).getPropertyValue('--mqrgb')||'34,211,238').trim();
    var MARK=['m48.8 35-1.5-4.1c-1-2.4-4.5-7.9-7.6-10.3-1.8-1.5-3.6-1.9-5.8-1.7-6.2 0.6-7.6 8.5-8.2 16h23.1v0.1z','m29.3 4.1-0.4-2.5-2.5 0.4 0.4 2.4c-3 0.6-5.4 3.3-5.4 6.8 0 4 3.1 7.6 7.2 7.6s7.1-3.2 7.1-7.5c0-3.5-2.8-7.1-6.4-7.2zm0 9.9c-1.4 0-3-1.4-3-3.1 0-1 0.6-2 1.5-2.5l-0.9-4 2.4-0.2 0.5 4.1c1.4 0.1 2.6 1.3 2.6 2.6 0 1.5-1.4 3.1-3.1 3.1z','m17.8 29.8c-2.1 0-4.1 1.4-4.9 3.4h-8c-1.9 0.2-1.3-1.6-1-2.5l4-10.7c0.5-1.4 1.3-2.4 1.6-1.2 1 3.8 3 9.8 3.1 9.9l2-0.5-4.6-23.7-2 0.5c-0.1 0-0.1 6.8 0.8 11.4-1.4 0.7-2.2 2.1-2.9 3.9l-3 7.9c-0.6 2-1.9 5-0.3 6.2 0.5 0.4 1 0.6 2 0.6h18.1c0-2.7-2-5.2-4.9-5.2z'];
    function sampleLogo(){
      var oc=document.createElement('canvas'); oc.width=W; oc.height=H; var o=oc.getContext('2d');
      if(!o.fill || typeof Path2D==='undefined') return [];
      o.fillStyle='#fff';
      var scale=Math.min(W*0.5/50, H*0.42/44);
      o.save(); o.translate(W/2 - 25.5*scale, H*0.4 - 21*scale); o.scale(scale,scale);
      for(var m=0;m<MARK.length;m++){ try{ o.fill(new Path2D(MARK[m])); }catch(e){} }
      o.restore();
      var d; try{ d=o.getImageData(0,0,W,H).data; }catch(e){ return []; }
      var pts=[], step=Math.max(3, Math.round(W/170));
      for(var y=0;y<H;y+=step){ for(var x=0;x<W;x+=step){ if(d[(y*W+x)*4+3]>128) pts.push([x,y]); } }
      return pts;
    }
    function build(){
      var box=$('#bgfx').getBoundingClientRect(); W=box.width||480; H=window.innerHeight;
      DPR=Math.min(2,window.devicePixelRatio||1); cv.width=W*DPR; cv.height=H*DPR; cv.style.width=W+'px'; cv.style.height=H+'px'; ctx.setTransform(DPR,0,0,DPR,0,0);
      targets=sampleLogo();
      N=Math.max(120, Math.min(targets.length||200, 900));
      var prev=dots; dots=[];
      for(var i=0;i<N;i++){ var p=prev[i];
        var tg=targets.length?targets[Math.floor(i*targets.length/N)]:[W/2,H/2];
        dots.push({ hx:p?p.hx:Math.random()*W, hy:p?p.hy:Math.random()*H, ph:p?p.ph:Math.random()*6.28,
          sp:p?p.sp:(0.2+Math.random()*0.5), r:p?p.r:(1.2+Math.random()*2.2),
          tx:tg[0]+(Math.random()*2-1)*3, ty:tg[1]+(Math.random()*2-1)*3,
          c:p?p.c:(Math.random()<0.5?rgb:'124,58,237') }); }
      // dense always-on drifting field (independent of assembly) so the bg is clearly alive
      var fn=Math.round(W*H/700), pf=free; free=[];
      for(var k=0;k<fn;k++){ var q=pf[k];
        free.push({ x:q?q.x:Math.random()*W, y:q?q.y:Math.random()*H, ph:q?q.ph:Math.random()*6.28,
          sp:q?q.sp:(0.15+Math.random()*0.5), r:q?q.r:(1+Math.random()*2),
          c:q?q.c:(Math.random()<0.5?rgb:'124,58,237') }); }
      window.__bgInfo={ W:W, H:H, free:free.length, dots:dots.length };
    }
    function sm(t){ t=t<0?0:t>1?1:t; return t*t*(3-2*t); }
    function frame(){
      var t=Date.now()*0.001;
      var maxS=Math.max(1,(document.documentElement.scrollHeight||document.body.scrollHeight)-window.innerHeight);
      var fr=Math.max(0,Math.min(1,(window.scrollY||window.pageYOffset||0)/maxS));
      var centers=[0.30,0.70], halfW=0.12, af=0;
      for(var c=0;c<centers.length;c++){ var dd=Math.abs(fr-centers[c])/halfW; if(dd<1){ var a=sm(1-dd); if(a>af) af=a; } }
      ctx.clearRect(0,0,W,H);
      // always-on drifting field
      for(var f=0;f<free.length;f++){ var ff=free[f];
        var ax=ff.x+Math.sin(t*ff.sp+ff.ph)*20, ay=ff.y+Math.cos(t*ff.sp*0.9+ff.ph)*20;
        ctx.beginPath(); ctx.fillStyle='rgba('+ff.c+','+(0.21-af*0.084).toFixed(3)+')'; ctx.arc(ax,ay,ff.r,0,6.28); ctx.fill(); }
      // assembly dots (gather into the wordmark at scroll peaks)
      for(var i=0;i<dots.length;i++){ var d=dots[i];
        var fx=d.hx+Math.sin(t*d.sp+d.ph)*22, fy=d.hy+Math.cos(t*d.sp*0.9+d.ph)*22;
        var x=fx+(d.tx-fx)*af, y=fy+(d.ty-fy)*af;
        var op=0.294+af*0.336;
        ctx.beginPath(); ctx.fillStyle='rgba('+d.c+','+op.toFixed(3)+')'; ctx.arc(x,y,d.r+af*0.7,0,6.28); ctx.fill();
      }
      requestAnimationFrame(frame);
    }
    build(); window.addEventListener('resize',build); frame();
  })();
})();
