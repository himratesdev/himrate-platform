/* HimRate landing — index page (TASK-060). The export's index.html was
   self-contained (its own canvas bg + nav + dataviz, no hr-shared.js); kept
   verbatim, with .html nav/CTA targets repointed to real Rails routes. The
   layout therefore does NOT load hr-shared.js on index (would double the
   canvas/nav). CSP-safe: externalised, no inline <script>. */

(function(){
  var CUR = location.pathname;
  var NAV = {
    'СТРИМЕРАМ':'/streamers','БРЕНДАМ':'/brands','ЗРИТЕЛЯМ':'/viewers',
    'МЕТОДОЛОГИЯ':'/methodology','ЦЕНЫ':'/methodology','МЕТОДОЛОГИЯ И ЦЕНЫ':'/methodology',
    'Стримерам':'/streamers','Брендам':'/brands','Зрителям':'/viewers',
    'Цены':'/methodology','Методология':'/methodology','Главная':'/'
  };
  function go(href){
    if(!href) return;
    if(href.toLowerCase()===CUR){ window.scrollTo({top:0,behavior:'smooth'}); return; }
    document.body.classList.add('hr-leaving');
    setTimeout(function(){ location.href = href; }, 240);
  }
  function cls(el){ return (typeof el.className==='string') ? el.className : ''; }

  // 1) Text-leaf navigation (header menu + footer links)
  document.querySelectorAll('div,span,a,p').forEach(function(el){
    if(el.querySelector('*')) return;
    var t = (el.textContent||'').trim();
    if(NAV[t]){
      el.setAttribute('data-hr-link','');
      el.addEventListener('click', function(e){ e.stopPropagation(); go(NAV[t]); });
    }
  });

  // 2) Logo wordmark -> home
  document.querySelectorAll('[data-pencil-name="Wordmark"]').forEach(function(el){
    el.setAttribute('data-hr-link','');
    el.addEventListener('click', function(){ go('/'); });
  });

  // 3) Buttons = real CTAs only: purple bg, OR rounded element whose text starts with an action verb.
  var ROUND = /rounded-\[(6|8|10|12|999)px\]/;
  var CTA = /^(подключить|установить|начать|связаться|все тарифы|оформить|выбрать|как это работает|как мы измеряем|узнать|смотреть|посмотреть|открыть метод|открыть демо|запросить|войти|я бренд|я зритель)/i;
  Array.prototype.slice.call(document.querySelectorAll('div')).forEach(function(el){
    var c = cls(el);
    var purple = /bg-\[#7C3AED\]/.test(c);
    var txt = (el.textContent||'').trim();
    var verb = ROUND.test(c) && CTA.test(txt) && txt.length<=64;
    if(!purple && !verb) return;
    if(txt.length===0 || txt.length>72) return;
    if(el.querySelector('[data-hr-btn]')) return;        // outermost CTA only
    el.setAttribute('data-hr-btn','');
    el.addEventListener('click', function(e){
      var s = txt.toLowerCase();
      var dest = null;
      if(s.indexOf('подключить')>-1) dest='/methodology';
      else if(s.indexOf('я бренд')>-1) dest='/brands';
      else if(s.indexOf('я зритель')>-1) dest='/viewers';
      else if(s.indexOf('как мы измеряем')>-1 || s.indexOf('методолог')>-1 || s.indexOf('как это работает')>-1) dest='/methodology';
      else if(s.indexOf('все тарифы')>-1 || s.indexOf('тариф')>-1) dest='/methodology';
      if(dest){ e.stopPropagation(); go(dest); }
    });
  });

  // 4) "Войти" -> pricing
  document.querySelectorAll('[data-pencil-name="Войти"]').forEach(function(el){
    el.setAttribute('data-hr-link','');
    el.addEventListener('click', function(){ go('/methodology'); });
  });
})();



(function(){
  function $(s,r){ return (r||document).querySelector(s); }
  function $all(s,r){ return Array.prototype.slice.call((r||document).querySelectorAll(s)); }
  function nbsp(n){ n=Math.round(n); var s=String(Math.abs(n)), o='', c=0; for(var i=s.length-1;i>=0;i--){ o=s[i]+o; if(++c%3===0&&i>0) o='\u202F'+o; } return (n<0?'-':'')+o; }
  function countNum(el, from, to, dur, suffix){ suffix=suffix||''; var st=Date.now(); if(el.__iv) clearInterval(el.__iv); el.__iv=setInterval(function(){ var p=Math.min(1,(Date.now()-st)/dur), e=1-Math.pow(1-p,3), v=from+(to-from)*e; el.textContent=(suffix==='%'?Math.round(v)+'%':nbsp(v)); if(p>=1){ clearInterval(el.__iv); el.__iv=null; } }, 16); }

  // ---------- (2) HERO card count-up ----------
  function runHero(){
    try{
      var hero=$('[data-pencil-name="Hero"]'); if(!hero) return true;
      if(!hero.__setup){
        var big=$('[data-pencil-name="big"]', hero), bar=$('[data-pencil-name="bar"]', hero);
        if(!big) return false;
        var bw=bar?bar.offsetWidth:0; if(bar && bw<=0) return false; // layout not ready
        if(bar){ bar.className=(bar.className||'').replace(/w-\[\d+(?:\.\d+)?px\]/,''); bar.style.minWidth='0'; bar.style.transition='width .12s linear'; }
        hero.__big=big; hero.__barEl=bar; hero.__bw=bw;
        hero.__pctT=$all('[data-pencil-name="t"]', hero).filter(function(e){ return /Аудитория реальная/.test(e.textContent||''); })[0]||null;
        hero.__setup=1;
      }
      // scroll-scrubbed count-up
      var y=window.scrollY||document.documentElement.scrollTop||0;
      var f=Math.max(0,Math.min(1, y/560)); f=f*f*(3-2*f);
      var v=Math.round(600+(4200-600)*f);
      if(hero.__big) hero.__big.textContent=nbsp(v);
      if(hero.__barEl) hero.__barEl.style.width=Math.round(hero.__bw*(v/4200))+'px';
      if(hero.__pctT) hero.__pctT.textContent='Аудитория реальная · '+Math.round(v/5000*100)+'%';
      return true;
    }catch(e){ return true; }
  }

  // ---------- (3) Real-audience meter — scroll-scrubbed 0->4200, red->yellow->green ----------
  function chipBy(meter,txt){ return $all('[data-pencil-name="'+txt+'"]', meter).filter(function(e){ return /p-\[7px_12px\]/.test(e.className||''); })[0]; }
  function runMeter(){
    try{
      var m=$('[data-pencil-name="Audience Meter"]'); if(!m) return true;
      if(!m.__setup){
        var value=$('[data-pencil-name="Value"]',m), pct=$('[data-pencil-name="pct"]',m), fill=$('[data-pencil-name="Fill"]',m);
        if(!fill) return false;
        var tw=fill.parentElement.getBoundingClientRect().width; if(tw<=0) return false;
        fill.className=(fill.className||'').replace(/w-\[\d+(?:\.\d+)?px\]/,'').replace(/bg-\[#?[0-9A-Fa-f]+\]/,'');
        fill.style.minWidth='0'; fill.style.transition='width .12s linear, background-color .2s ease';
        if(value) value.className=(value.className||'').replace(/text-\[#?[0-9A-Fa-f]{3,8}\]/,'');
        if(pct) pct.className=(pct.className||'').replace(/text-\[#?[0-9A-Fa-f]{3,8}\]/,'');
        m.__v=value; m.__pct=pct; m.__fill=fill;
        m.__cReal=chipBy(m,'Аудитория реальная'); m.__cYel=chipBy(m,'Аномалия онлайна'); m.__cRed=chipBy(m,'Значительная аномалия');
        [m.__cReal,m.__cYel,m.__cRed].forEach(function(c){ if(c) c.style.transition='opacity .3s ease, transform .3s ease'; });
        m.__setup=1;
      }
      var H=window.innerHeight||800, rect=m.getBoundingClientRect();
      var p=Math.max(0,Math.min(1,(H*0.85-rect.top)/(H*0.6)));
      var tw=m.__fill?m.__fill.parentElement.getBoundingClientRect().width:0;
      var v=Math.round(p*4200), pctV=Math.round(v/5000*100);
      var RED='#F87171', YEL='#FBBF24', CYAN='#22D3EE', col, active;
      if(v<2000){ col=RED; active=m.__cRed; } else if(v<3500){ col=YEL; active=m.__cYel; } else { col=CYAN; active=m.__cReal; }
      if(m.__fill){ m.__fill.style.width=Math.round(tw*(v/5000))+'px'; m.__fill.style.background=col; }
      if(m.__v){ m.__v.textContent=nbsp(v); m.__v.style.color=col; }
      if(m.__pct){ m.__pct.textContent=pctV+'%'; m.__pct.style.color=col; }
      [m.__cReal,m.__cYel,m.__cRed].forEach(function(c){ if(c){ c.style.opacity='.3'; c.style.transform='scale(1)'; } });
      if(active){ active.style.opacity='1'; active.style.transform='scale(1.06)'; }
      return true;
    }catch(e){ return true; }
  }

  // ---------- (4) Platforms marquee: equal chips, drift left->right ----------
  function fixMarquee(){
    try{
      var mq=$('[data-pencil-name="Marquee"]'); if(!mq) return;
      var strip=$('[data-pencil-name="Strip"]', mq); if(!strip) return;
      mq.style.overflow='hidden';
      var kids=$all(':scope > *', strip);
      // keep exactly 8 (two seamless sets of 4 unique)
      while(strip.children.length>8) strip.removeChild(strip.lastElementChild);
      $all(':scope > *', strip).forEach(function(ch){ ch.style.flex='0 0 auto'; ch.style.width='248px'; ch.style.justifyContent='center'; });
      strip.style.width='max-content';
      strip.style.animation='hrMarquee 26s linear infinite';
      strip.style.willChange='transform';
    }catch(e){}
  }

  // ---------- (5) Demo tile: animate chat bars + play pulse instead of static video ----------
  function animDemo(){
    try{
      var d=$('[data-pencil-name="Демо-плитка"]'); if(!d) return true; if(d.__hrDemo) return true;
      // chat bars = leaf vertical bars
      var bars=$all('div', d).filter(function(el){ if(el.children.length) return false; var c=el.className||''; var r=el.getBoundingClientRect(); return /bg-\[#/.test(c) && r.width>3 && r.width<28 && r.height>14 && r.height>r.width; });
      if(!bars.length) return false; // Tailwind layout not applied yet — retry later
      d.__hrDemo=1;
      bars.forEach(function(b,i){ b.style.transformOrigin='bottom'; b.style.animation='hrChat 1.9s ease-in-out '+(i*0.07).toFixed(2)+'s infinite'; });
      // video tile = the "ВИДЕО СТРИМЕРА" sub-tile (large left area)
      var tile=$all('div', d).filter(function(el){ var r=el.getBoundingClientRect(); return r.width>240 && r.height>150 && /ВИДЕО/.test(el.textContent||'') && (el.textContent||'').replace(/\s+/g,' ').trim().length<40; }).sort(function(a,b){ return a.getBoundingClientRect().width-b.getBoundingClientRect().width; })[0];
      if(tile){
        var cs=getComputedStyle(tile); if(cs.position==='static') tile.style.position='relative'; tile.style.overflow='hidden';
        var bars2=''; for(var bi=0; bi<11; bi++){ bars2+='<span style="width:5px;height:26px;border-radius:3px;background:linear-gradient(180deg,#A855F7,#7C3AED);transform-origin:bottom;transform:scaleY(.3);animation:hrEqBar '+(0.7+(bi%4)*0.15).toFixed(2)+'s ease-in-out '+(bi*0.06).toFixed(2)+'s infinite;"></span>'; }
        tile.innerHTML='<div style="position:absolute;inset:0;display:flex;flex-direction:column;align-items:center;justify-content:center;gap:16px;">'
          +'<div style="position:absolute;width:210px;height:210px;border-radius:50%;background:radial-gradient(circle,rgba(124,58,237,.3),transparent 68%);"></div>'
          +'<div style="position:absolute;top:14px;left:16px;display:flex;align-items:center;gap:6px;font:600 11px Geist Mono,monospace;color:#fff;letter-spacing:1.5px;"><span style="width:8px;height:8px;border-radius:50%;background:#F2415A;animation:hrLive 1.2s ease-in-out infinite;"></span>LIVE</div>'
          +'<div style="position:relative;animation:hrBob 3s ease-in-out infinite;"><div style="position:relative;width:88px;height:88px;">'
          +'<div style="position:absolute;top:-6px;left:50%;transform:translateX(-50%);width:80px;height:44px;border:5px solid #A855F7;border-bottom:none;border-radius:44px 44px 0 0;"></div>'
          +'<div style="position:absolute;inset:0;border-radius:50%;background:linear-gradient(160deg,#2C2742,#1A1726);border:2px solid #7C3AED;"></div>'
          +'<div style="position:absolute;top:32px;left:-7px;width:13px;height:24px;border-radius:6px;background:#A855F7;"></div>'
          +'<div style="position:absolute;top:32px;right:-7px;width:13px;height:24px;border-radius:6px;background:#A855F7;"></div>'
          +'<div style="position:absolute;top:40px;left:27px;width:9px;height:9px;border-radius:50%;background:#EDEAF7;"></div>'
          +'<div style="position:absolute;top:40px;right:27px;width:9px;height:9px;border-radius:50%;background:#EDEAF7;"></div>'
          +'<div style="position:absolute;top:58px;left:50%;transform:translateX(-50%);width:26px;height:13px;border:2px solid #EDEAF7;border-top:none;border-radius:0 0 26px 26px;"></div>'
          +'</div></div>'
          +'<div style="display:flex;align-items:flex-end;gap:4px;height:26px;">'+bars2+'</div>'
          +'<div style="font:600 10px Geist Mono,monospace;color:#9A95A8;letter-spacing:2px;">В ЭФИРЕ</div>'
          +'</div>';
      }
      return true;
    }catch(e){ return true; }
  }

  // ---------- (6) Twitch-vs grid: shrink cards, bump small text ----------
  function shrinkGrid(){
    try{
      var g=$('[data-pencil-name="Grid"]'); if(!g||g.__grid) return;
      var cards=[]; $all(':scope > *', g).forEach(function(row){ $all(':scope > *', row).forEach(function(c){ cards.push(c); }); row.style.display='none'; });
      if(!cards.length) return; g.__grid=1;
      g.style.display='grid'; g.style.gridTemplateColumns='repeat(6,1fr)'; g.style.gap='12px'; g.style.alignItems='stretch';
      cards.forEach(function(c,i){ c.className=(c.className||'').replace(/h-\[\d+px\]/,''); c.style.height='auto'; c.style.padding='14px 16px'; c.style.gridColumn=(i<3?'span 2':'span 3'); g.appendChild(c); });
      $all('div', g).forEach(function(el){ if(el.children.length) return; var c=el.className||''; var m=c.match(/text-\[(\d+(?:\.\d+)?)px\]/); if(m){ var px=parseFloat(m[1]); if(px>=11 && px<=14){ el.style.fontSize=(px+1)+'px'; } } });
      var sec=$('[data-pencil-name="Sec TwitchVsUs NEW"]'); if(sec){ sec.style.paddingTop='52px'; sec.style.paddingBottom='40px'; }
    }catch(e){}
  }

  // ---------- (7) "7 сигналов" chips into one row ----------
  function oneRowSignals(){
    try{
      var cc=$('[data-pencil-name="Checks Compact"]'); if(!cc) return;
      var chipRows=$all(':scope > *', cc).filter(function(el){ return /\b0[1-9]\b/.test(el.textContent||''); });
      if(!chipRows.length) return;
      var first=chipRows[0];
      chipRows.forEach(function(r,i){ if(i===0) return; $all(':scope > *', r).forEach(function(ch){ first.appendChild(ch); }); r.style.display='none'; });
      first.style.flexWrap='nowrap'; first.style.gap='6px'; first.style.width='100%';
      $all(':scope > *', first).forEach(function(ch){ ch.style.flex='1 1 0'; ch.style.minWidth='0'; ch.style.padding='7px 7px'; ch.style.justifyContent='center';
        $all('div', ch).forEach(function(t){ if(t.children.length) return; var c=t.className||''; var mm=c.match(/text-\[(\d+(?:\.\d+)?)px\]/); if(mm && parseFloat(mm[1])>9){ t.style.fontSize='10.5px'; } t.style.whiteSpace='nowrap'; t.style.overflow='hidden'; t.style.textOverflow='ellipsis'; });
      });
    }catch(e){}
  }

  // ---------- (8) Big-idea rows: equal-height columns, fill vertical space, align ----------
  function balanceRows(){
    try{
      ['Ряд · Стримеру','Ряд · Бренду','Audience Cards'].forEach(function(name){
        var row=$('[data-pencil-name="'+name+'"]'); if(!row) return;
        row.className=(row.className||'').replace(/h-\[\d+px\]/,'');
        row.style.alignItems='stretch'; row.style.height='auto';
        var jc=(name==='Audience Cards')?'space-between':'flex-start';
        $all(':scope > *', row).forEach(function(col){ col.className=(col.className||'').replace(/overflow-hidden/,'').replace(/h-full/,''); col.style.display='flex'; col.style.flexDirection='column'; col.style.justifyContent=jc; col.style.height='auto'; col.style.overflow='visible'; });
      });
      // remove the "ГЛАВНОЕ" badge (whole chip) on the СТРИМЕР card
      var ac=$('[data-pencil-name="Audience Cards"]'); if(ac){ $all('div', ac).forEach(function(e){ if(!e.children.length && (e.textContent||'').trim()==='ГЛАВНОЕ'){ var chip=(e.parentElement && /rounded|bg-\[#/.test(e.parentElement.className||''))?e.parentElement:e; chip.style.display='none'; } }); }
    }catch(e){}
  }

  // ---------- (9) Hover purple-ring on content cards ----------
  function tagCards(){
    try{
      var RND=/rounded-\[(10|12|14|16|18|20|24)px\]/;
      ['Audience Cards','Grid','Ряд · Стримеру','Ряд · Бренду','Плитки доверия','Демо-плитка'].forEach(function(name){
        var c=$('[data-pencil-name="'+name+'"]'); if(!c) return;
        $all(':scope > *', c).forEach(function(ch){ if(RND.test(ch.className||'')) ch.setAttribute('data-hr-card',''); });
      });
      var tiles=$('[data-pencil-name="Tiles"]'); if(tiles){ $all(':scope > *', tiles).forEach(function(ch){ ch.setAttribute('data-hr-scale',''); }); }
    }catch(e){}
  }

  // ---------- (10) Wire "Я бренд/Я зритель" + audience-card CTAs (hover square + navigation) ----------
  function navTo(href){ document.body.classList.add('hr-leaving'); setTimeout(function(){ location.href=href; }, 240); }
  function wireCTAs(){
    try{
      // primary hero CTA (the filled square) — dim it while a sibling ghost link is hovered
      var primary=null;
      $all('div').forEach(function(e){ if(e.children.length) return; if((e.textContent||'').trim()==='Подключить канал — бесплатно'){ var p=e.parentElement; primary=(p&&/bg-\[#7C3AED\]/.test(p.className||''))?p:e; } });
      if(primary) primary.style.transition='opacity .18s ease';
      function dim(on){ if(primary) primary.style.opacity=on?'.28':'1'; }
      // hero «Я бренд / Я зритель» → hover square + nav, and hide the left square while hovered
      $all('div').forEach(function(e){ if(e.children.length||e.__w) return; var tx=(e.textContent||'').trim(); var dest=null;
        if(/^Я бренд/.test(tx)) dest='/brands';
        else if(/^Я зритель/.test(tx)) dest='/viewers';
        else if(/^Я стример/.test(tx)) dest='/streamers';
        if(!dest) return;
        e.__w=1; e.setAttribute('data-hr-cta','');
        e.addEventListener('mouseenter', function(){ dim(true); }); e.addEventListener('mouseleave', function(){ dim(false); });
        e.addEventListener('click', function(){ navTo(dest); });
      });
      // audience-card CTAs → square outline on hover + nav; keep filled button ghosted (already a square)
      var ac=$('[data-pencil-name="Audience Cards"]'); if(ac){
        $all('div', ac).forEach(function(e){ if(e.children.length) return; var tx=(e.textContent||'').trim(); var dest=null;
          if(/Подключить свой канал/.test(tx)) dest='/methodology';
          else if(/Как мы измеряем/.test(tx)) dest='/methodology';
          else if(/Установить расширение/.test(tx)) dest='/viewers';
          if(!dest) return;
          var btn=e, par=e.parentElement;
          // strip the generic square button-ring from ancestors so the CTA shows ONE oval ring
          var up=e, k=0; while(up && k<3){ up.removeAttribute&&up.removeAttribute('data-hr-btn'); up=up.parentElement; k++; }
          if(par && /bg-\[#7C3AED\]/.test(par.className||'')){
            par.className=(par.className||'').replace(/bg-\[#7C3AED\]/g,'').replace(/p-\[[^\]]*\]/g,'').replace(/rounded-\[[^\]]*\]/g,'');
            par.style.setProperty('background','transparent','important'); par.style.setProperty('border','none','important'); par.style.setProperty('padding','0','important'); e.style.color='#22D3EE'; btn=par;
            e.setAttribute('data-hr-cta','');
          }else{
            e.setAttribute('data-hr-cta','');
          }
          if(!btn.__w){ btn.__w=1; btn.addEventListener('click', function(ev){ ev.stopPropagation(); navTo(dest); }); }
        });
      }
    }catch(e){}
  }

  // ---------- (1) Background: dots that assemble into "HimRate" on scroll ----------
  var __hrBgInit=false;
  function bg(){
    try{
      /* Desktop layer only — mobile .app has its own #bgfx canvas (no double-paint). */
      if((window.innerWidth||document.documentElement.clientWidth||0) < 1024) return true;
      var root=$('[data-pencil-name="Главная"]'); if(!root) return true;
      var fx=document.getElementById('hr-bgfx');
      if(!fx){ fx=document.createElement('div'); fx.id='hr-bgfx'; document.body.insertBefore(fx, document.body.firstChild); }
      root.style.position='relative'; root.style.zIndex='1'; root.style.background='transparent';
      var cleared=0;
      $all('div', root).forEach(function(el){
        var r=el.getBoundingClientRect(); if(r.width<860 || r.height<120) return;
        var m=(getComputedStyle(el).backgroundColor||'').match(/rgba?\((\d+),\s*(\d+),\s*(\d+)/);
        if(!m) return; var rr=+m[1], gg=+m[2], bb=+m[3];
        if(rr<11 && gg<11 && bb<18){ el.style.background='transparent'; cleared++; }
      });
      $all('[data-pencil-name="CTA Dot Field"]').forEach(function(f){ f.style.display='none'; });
      // hide the hero's own dot field so the live canvas drives the dots from the very first block
      $all('[data-pencil-name="Dot BG"]').forEach(function(f){ f.style.display='none'; });
      if(!__hrBgInit){ __hrBgInit=true; initBgCanvas(fx); }
      return cleared>0;
    }catch(e){ return true; }
  }

  function initBgCanvas(fx){
    var cv=document.createElement('canvas'); fx.appendChild(cv);
    var ctx=cv.getContext('2d'); var DPR=Math.min(2, window.devicePixelRatio||1);
    var W=0, H=0, logo=[], free=[], cx=0, cy=0;
    var MARK=[
      "m24.7 4.5 0.7 3.2c1 0.3 2 1.2 2 2.3 0 1.3-1.1 2.5-2.6 2.5-1.2 0-2.5-1-2.5-2.5 0-0.8 0.4-1.5 1.1-2l-0.7-3.2c-2.7 0.5-4.6 2.8-4.6 5.6 0 3.3 2.6 6.1 6 6.1 3.2 0 6-2.5 6.1-6 0.1-2.9-2.3-5.7-5.5-6z",
      "m22.4 2.6 1.9-0.4 0.4 2.2c-0.6-0.1-1.3 0-1.9 0.1l-0.4-1.9z",
      "m33.6 18.6c-1.4-1.2-4.8-2.6-7.4-0.6-2.6 2.2-4.2 5.8-4.6 12.3h19.3c-1.5-4.8-5.6-9.9-7.3-11.7z",
      "m14.7 26.2c-1.6 0.2-3.2 1.3-4 2.9h-6.4c-0.7 0-1.4-0.2-1-1.5 0.6-2.3 3.1-8.7 3.8-10.8 0.2-0.6 0.5-0.8 0.7-0.8 0.9 4 2.1 8.3 2.8 9l1.6-0.4-3.9-20-1.7 0.4c-0.1 2.8 0.4 6.6 1 9.7-0.7 0.2-1.2 0.6-1.6 1.3-0.9 1.9-3.8 9-4.1 11.7-0.3 1.2 0.3 2.6 2 2.6h15.1c0-2.3-2-4.1-4.3-4.1z"
    ];
    function build(){
      W=window.innerWidth||1440; H=window.innerHeight||800;
      cv.width=W*DPR; cv.height=H*DPR; cv.style.width=W+'px'; cv.style.height=H+'px';
      ctx.setTransform(DPR,0,0,DPR,0,0);
      var oc=document.createElement('canvas'); oc.width=W; oc.height=H; var ox=oc.getContext('2d');
      var fs=Math.max(58, Math.min(W*0.125, 184));
      ox.fillStyle='#fff'; ox.textBaseline='middle'; ox.textAlign='left';
      ox.font='800 '+fs+'px "Playfair Display", Georgia, serif';
      var textW=ox.measureText('HimRate').width;
      var markH=fs*1.2, markW=markH*(42/38), gap=fs*0.32;
      var totalW=markW+gap+textW, startX=Math.round((W-totalW)/2), cy=Math.round(H*0.5);
      // logo mark via Path2D (no image load, no canvas taint)
      try{ ox.save(); ox.translate(startX, cy-markH/2); ox.scale(markW/42, markH/38);
        for(var pI=0;pI<MARK.length;pI++){ ox.fill(new Path2D(MARK[pI])); } ox.restore();
      }catch(e){}
      ox.fillText('HimRate', startX+markW+gap, cy);
      var d=null; try{ d=ox.getImageData(0,0,W,H).data; }catch(e){ d=null; }
      var targets=[];
      if(d){ var step=Math.max(5, Math.round(fs/30));
        for(var yy=0; yy<H; yy+=step){ for(var xx=0; xx<W; xx+=step){ if(d[(yy*W+xx)*4+3]>128) targets.push([xx,yy]); } } }
      var CAP=1500;
      if(targets.length>CAP){ var keep=[]; var sk=targets.length/CAP; for(var k=0;k<CAP;k++) keep.push(targets[Math.floor(k*sk)]); targets=keep; }
      // logo dots (preserve homes across rebuilds)
      cx=0; cy=0; for(var ci=0; ci<targets.length; ci++){ cx+=targets[ci][0]; cy+=targets[ci][1]; } if(targets.length){ cx/=targets.length; cy/=targets.length; }
      var prev=logo; logo=[];
      for(var i=0;i<targets.length;i++){ var p=prev[i];
        logo.push({ hx:p?p.hx:Math.random()*W, hy:p?p.hy:Math.random()*H, tx:targets[i][0], ty:targets[i][1],
          ph:p?p.ph:Math.random()*6.2832, sp:p?p.sp:(0.52+Math.random()*1.05), r:p?p.r:(0.8+Math.random()*1.3),
          dir:p?p.dir:(Math.random()<0.5?-1:1), col:p?p.col:(Math.random()<0.5?'34,211,238':'99,102,241') });
      }
      void 0;
      // free ambient dots — always scattered, so dots stay on the sides while the logo forms
      if(free.length===0){ var fn=Math.round((targets.length||600)*1.05);
        for(var j=0;j<fn;j++){ free.push({ hx:Math.random()*W, hy:Math.random()*H, ph:Math.random()*6.2832, sp:0.34+Math.random()*0.95, r:0.7+Math.random()*1.3, col:(Math.random()<0.5?'34,211,238':'99,102,241') }); }
      } else { for(var f2=0; f2<free.length; f2++){ if(free[f2].hx>W) free[f2].hx=Math.random()*W; if(free[f2].hy>H) free[f2].hy=Math.random()*H; } }
    }
    function gauss(p,c,w){ var x=(p-c)/w; return Math.exp(-x*x); }
    var ANCH=[
      {sel:'[data-pencil-name="Sec Platforms NEW"]', s:0, cf:0.5, sa:0.95, sb:0.5},        // 1: lands on the open "Платформы" block; forms from the first scroll
      {sel:'[data-pencil-name="Sec TwitchVsUs NEW"]', s:1, cf:0.16, sa:0.34, sb:0.26},      // 2: assembles a bit later, disperses a bit earlier
      {sel:'[data-pencil-name="Секция 1 — Результат бренду"]', s:2, cf:0.16, sa:0.42, sb:0.42}, // 3: brand heading open zone
      {sel:'[data-pencil-name="S15 Финальный CTA"]', s:0, cf:-0.15, sa:0.52, sb:0.52}          // 4: open final CTA (assembles earlier)
    ];
    function frame(){
      var y=window.scrollY||document.documentElement.scrollTop||0;
      var maxH=Math.max(1,(document.body.scrollHeight||document.documentElement.scrollHeight)-window.innerHeight);
      // assembly peaks anchored to specific sections: logo forms just before each text appears
      var H=window.innerHeight||800;
      var t=0, style=0;
      for(var ai=0; ai<ANCH.length; ai++){
        var el=ANCH[ai].__el; if(!el){ el=document.querySelector(ANCH[ai].sel); ANCH[ai].__el=el; }
        if(!el) continue;
        var rect=el.getBoundingClientRect();
        var d=(rect.top + rect.height*ANCH[ai].cf) - H*0.5;   // distance of the block's open zone from viewport centre
        var sig=(d>0?ANCH[ai].sa:ANCH[ai].sb)*H;              // asymmetric: sa while approaching, sb while leaving
        var x=d/sig;
        var ti=Math.exp(-x*x);
        if(ti>t){ t=ti; style=ANCH[ai].s; }
      }
      var time=Date.now()*0.001;
      ctx.clearRect(0,0,W,H);
      // side/ambient dots — always drifting
      for(var f=0; f<free.length; f++){ var ff=free[f];
        var fax=ff.hx+Math.sin(time*ff.sp+ff.ph)*36, fay=ff.hy+Math.cos(time*ff.sp*0.9+ff.ph)*36;
        ctx.beginPath(); ctx.fillStyle='rgba('+ff.col+',0.2)'; ctx.arc(fax,fay,ff.r,0,6.2832); ctx.fill();
      }
      var drift=1-t;
      for(var i=0;i<logo.length;i++){ var dd=logo[i];
        var sx=dd.hx+Math.sin(time*dd.sp+dd.ph)*34*drift, sy=dd.hy+Math.cos(time*dd.sp*0.9+dd.ph)*34*drift;
        var px, py;
        if(style===1){ // spiral swoosh — curved approach along a perpendicular arc
          var lx=sx+(dd.tx-sx)*t, ly=sy+(dd.ty-sy)*t;
          var vx=-(dd.ty-sy), vy=(dd.tx-sx), vl=Math.sqrt(vx*vx+vy*vy)||1, sw=Math.sin(t*Math.PI)*48*dd.dir;
          px=lx+vx/vl*sw; py=ly+vy/vl*sw;
        } else if(style===2){ // wave — assemble left -> right
          var lt=(t-(dd.tx/(W||1))*0.5)/0.5; lt=lt<0?0:(lt>1?1:lt); lt=lt*lt*(3-2*lt);
          px=sx+(dd.tx-sx)*lt; py=sy+(dd.ty-sy)*lt;
        } else if(style===3){ // explode out, then implode into the logo
          var bl=Math.sin(t*Math.PI);
          px=sx+(dd.tx-sx)*t + (dd.tx-cx)*0.55*bl;
          py=sy+(dd.ty-sy)*t + (dd.ty-cy)*0.55*bl;
        } else { // 0: direct drift-in
          px=sx+(dd.tx-sx)*t; py=sy+(dd.ty-sy)*t;
        }
        var a=0.14+t*0.64;
        ctx.beginPath(); ctx.fillStyle='rgba('+dd.col+','+a.toFixed(3)+')'; ctx.arc(px,py,dd.r+t*0.6,0,6.2832); ctx.fill();
      }
    }
    build();
    var rt; window.addEventListener('resize', function(){ clearTimeout(rt); rt=setTimeout(build,180); });
    if(fx.__loop) clearInterval(fx.__loop);
    fx.__loop=setInterval(frame, 33);
  }

  function geomPoll(){
    var tries=0;
    (function attempt(){
      var ok = true;
      if(!animDemo()) ok=false;
      if(!runHero()) ok=false;
      if(!runMeter()) ok=false;
      if(!bg()) ok=false;
      if(ok || tries>60) return;
      tries++; setTimeout(attempt, 200);
    })();
  }
  function init(){
    // Desktop-only layout rebuilders (6-col grid, one-row chips, equalisation):
    // below lg the page stacks and responsive CSS owns the layout.
    var DESK = (window.innerWidth || document.documentElement.clientWidth || 0) >= 1024;
    fixMarquee();
    if (DESK) { shrinkGrid(); oneRowSignals(); balanceRows(); }
    tagCards(); wireCTAs();
    geomPoll();
    // scroll-scrubbed numbers (hero card + audience meter), updated continuously
    if(!window.__hrScrub){ window.__hrScrub=setInterval(function(){ runHero(); runMeter(); }, 33); }
  }
  if(document.readyState==='complete'||document.readyState==='interactive') setTimeout(init,300);
  else window.addEventListener('DOMContentLoaded', function(){ setTimeout(init,300); });
  window.addEventListener('load', function(){ setTimeout(geomPoll, 50); });
})();



(function(){
  var ACCENT='#67E8F9';
  function go(){ try{ Array.prototype.slice.call(document.querySelectorAll('[data-pencil-name="Wordmark"] svg [fill]')).forEach(function(n){ var f=(n.getAttribute('fill')||'').toUpperCase(); if(f && f!=='#FFFFFF' && f!=='#FFF' && f!=='WHITE' && f!=='NONE'){ n.setAttribute('fill', ACCENT); } }); }catch(e){} }
  if(document.readyState!=='loading'){ setTimeout(go,800); setTimeout(go,1600); } else window.addEventListener('DOMContentLoaded', function(){ setTimeout(go,800); setTimeout(go,1600); });
})();



(function(){
  function q(n,r){ return (r||document).querySelector('[data-pencil-name="'+n+'"]'); }
  var _w=[];
  function tick(){ _w.forEach(function(f){ try{f();}catch(e){} }); }
  function prog(el, enter, span){ var H=window.innerHeight||800, r=el.getBoundingClientRect(); return Math.max(0,Math.min(1,(H*(enter||0.9)-r.top)/(H*(span||0.55)))); }
  function start(){
    /* channels (① куда утекает) — count values up + grow bars on scroll */
    var ch=q('channels');
    if(ch){
      var rows=Array.prototype.slice.call(ch.children).map(function(row){
        var v=q('v',row), bar=q('bar',row);
        var to=v?parseInt((v.textContent||'').replace(/\D/g,''),10):0;
        var bw=0; if(bar){ var m=(bar.className||'').match(/w-\[(\d+(?:\.\d+)?)px\]/); bw=m?parseFloat(m[1]):0; bar.className=(bar.className||'').replace(/w-\[\d+(?:\.\d+)?px\]/,''); bar.style.minWidth='0'; bar.style.transition='width .12s linear'; }
        return {v:v,bar:bar,to:to,bw:bw};
      });
      function fch(){ var p=prog(ch);
        rows.forEach(function(o,i){ var l=Math.max(0,Math.min(1,(p - i*0.1)/0.5)), e=l*l*(3-2*l);
          if(o.v && o.to) o.v.textContent=Math.round(o.to*e);
          if(o.bar) o.bar.style.width=(o.bw*e).toFixed(1)+'px';
        });
      }
      _w.push(fch); fch();
    }
    /* histogram (② почему ушли) + chartArea (③ эфир приводит клиентов) — bars fill on scroll */
    [['histogram',0.03],['chartArea',0.04]].forEach(function(cfg){
      var box=q(cfg[0]); if(!box) return;
      var bars=Array.prototype.slice.call(box.children);
      bars.forEach(function(b){ b.style.transformOrigin='center bottom'; b.style.transition='transform .12s linear'; });
      function fr(){ var p=prog(box);
        bars.forEach(function(b,i){ var l=Math.max(0,Math.min(1,(p - i*cfg[1])/0.4)), e=l*l*(3-2*l); b.style.transform='scaleY('+e.toFixed(3)+')'; });
      }
      _w.push(fr); fr();
    });
    document.addEventListener('scroll', tick, true);
    window.addEventListener('resize', tick);
    (function loop(){ tick(); requestAnimationFrame(loop); })();
  }
  if(document.readyState!=='loading') setTimeout(start,750); else window.addEventListener('DOMContentLoaded',function(){ setTimeout(start,750); });
})();
