/* HimRate — shared landing enhancement layer.
   Configure per page BEFORE this script:
     window.HR = {
       root:   '[data-pencil-name="Зрителям"]',   // page root wrapper
       word:   'ЖИВЫЕ',                            // glyph the dots assemble into
       accent: ['34,211,238','99,102,241'],        // two dot colours (rgb tuples)
       styles: [0,2,3]                             // assembly motions used at the 3 scroll peaks
     };
   Falls back to sensible defaults if HR is missing. */
(function(){
  var CFG = window.HR || {};
  var ROOT_SEL = CFG.root || null;
  var WORD = CFG.word || 'HimRate';
  var COLS = (CFG.accent && CFG.accent.length) ? CFG.accent : ['34,211,238','99,102,241'];
  var STYLES = (CFG.styles && CFG.styles.length) ? CFG.styles : [0,2,3];
  var SHAPE = CFG.shape || null;

  /* ---- glyph shapes drawn onto the offscreen canvas (white = dotted) ---- */
  var SHAPES = {
    graph: function(ox,cx,cy,S){
      ox.strokeStyle='#fff'; ox.lineJoin='round'; ox.lineCap='round';
      var x0=cx-S*0.46, y0=cy+S*0.34, w=S*0.92, h=S*0.62;
      ox.lineWidth=S*0.028; ox.beginPath(); ox.moveTo(x0,y0-h); ox.lineTo(x0,y0); ox.lineTo(x0+w,y0); ox.stroke();
      var pts=[[0,0.1],[0.22,0.32],[0.42,0.24],[0.62,0.6],[0.82,0.72],[1,0.98]];
      ox.lineWidth=S*0.08; ox.beginPath();
      for(var i=0;i<pts.length;i++){ var px=x0+pts[i][0]*w, py=y0-pts[i][1]*h; if(i===0) ox.moveTo(px,py); else ox.lineTo(px,py); }
      ox.stroke();
      var ex=x0+w, ey=y0-0.98*h; ox.lineWidth=S*0.07; ox.beginPath(); ox.moveTo(ex-S*0.16,ey-S*0.02); ox.lineTo(ex,ey); ox.lineTo(ex-S*0.02,ey+S*0.16); ox.stroke();
    },
    bars: function(ox,cx,cy,S){
      ox.fillStyle='#fff'; var n=5, cell=S/n, bw=cell*0.58, Hgt=S*0.82, y0=cy+S*0.44, x0=cx-S*0.5+cell*0.21;
      var hs=[0.34,0.52,0.7,0.86,1.0];
      for(var i=0;i<n;i++){ var bh=hs[i]*Hgt; ox.fillRect(x0+i*cell, y0-bh, bw, bh); }
    },
    play: function(ox,cx,cy,S){
      ox.strokeStyle='#fff'; ox.fillStyle='#fff'; ox.lineWidth=S*0.07;
      ox.beginPath(); ox.arc(cx,cy,S*0.42,0,6.2832); ox.stroke();
      var t=S*0.21; ox.beginPath(); ox.moveTo(cx-t*0.55,cy-t); ox.lineTo(cx-t*0.55,cy+t); ox.lineTo(cx+t*0.98,cy); ox.closePath(); ox.fill();
    },
    gauge: function(ox,cx,cy,S){
      ox.strokeStyle='#fff'; ox.fillStyle='#fff'; ox.lineCap='round';
      var R=S*0.42, yc=cy+S*0.18;
      ox.lineWidth=S*0.09; ox.beginPath(); ox.arc(cx,yc,R,Math.PI,2*Math.PI); ox.stroke();
      var ang=1.7*Math.PI; ox.lineWidth=S*0.05; ox.beginPath(); ox.moveTo(cx,yc); ox.lineTo(cx+Math.cos(ang)*R*0.9, yc+Math.sin(ang)*R*0.9); ox.stroke();
      ox.beginPath(); ox.arc(cx,yc,S*0.06,0,6.2832); ox.fill();
    },
    live: function(ox,cx,cy,S){
      ox.fillStyle='#fff'; ox.textBaseline='middle'; ox.textAlign='left';
      var fs=S*0.42; ox.font='800 '+fs+'px "Space Grotesk","Geist Mono",Georgia,sans-serif';
      var label='LIVE', tw=ox.measureText(label).width, dotR=S*0.14, gap=S*0.16;
      var total=dotR*2+gap+tw, x0=cx-total/2, mid=cy;
      ox.beginPath(); ox.arc(x0+dotR, mid, dotR, 0, 6.2832); ox.fill();
      ox.fillText(label, x0+dotR*2+gap, mid);
    },
    chat: function(ox,cx,cy,S){
      ox.strokeStyle='#fff'; ox.fillStyle='#fff'; ox.lineJoin='round';
      function bubble(bx,by,bw,bh,tailLeft){
        var r=bh*0.42; ox.lineWidth=S*0.04;
        ox.beginPath(); ox.moveTo(bx+r,by);
        ox.arcTo(bx+bw,by,bx+bw,by+bh,r); ox.arcTo(bx+bw,by+bh,bx,by+bh,r);
        ox.arcTo(bx,by+bh,bx,by,r); ox.arcTo(bx,by,bx+bw,by,r); ox.closePath(); ox.stroke();
        ox.beginPath();
        if(tailLeft){ ox.moveTo(bx+bw*0.30,by+bh-1); ox.lineTo(bx+bw*0.14,by+bh+bh*0.5); ox.lineTo(bx+bw*0.5,by+bh-1); }
        else { ox.moveTo(bx+bw*0.5,by+bh-1); ox.lineTo(bx+bw*0.86,by+bh+bh*0.5); ox.lineTo(bx+bw*0.7,by+bh-1); }
        ox.closePath(); ox.fill();
        for(var i=0;i<3;i++){ ox.beginPath(); ox.arc(bx+bw*0.32+i*bw*0.18, by+bh*0.52, bh*0.11, 0, 6.2832); ox.fill(); }
      }
      var w=S*0.66, h=S*0.3;
      bubble(cx-S*0.48, cy-S*0.4, w, h, true);
      bubble(cx-S*0.18, cy+S*0.06, w, h, false);
    }
  };

  function $(s,r){ return (r||document).querySelector(s); }
  function $all(s,r){ return Array.prototype.slice.call((r||document).querySelectorAll(s)); }
  function cls(el){ return (typeof el.className==='string') ? el.className : ''; }

  /* ---------------- styles ---------------- */
  function injectCSS(){
    if(document.getElementById('hr-shared-style')) return;
    var s=document.createElement('style'); s.id='hr-shared-style';
    s.textContent = [
      '[data-hr-link]{ cursor:pointer; transition: opacity .15s ease; }',
      '[data-hr-link]:hover{ opacity:.62; }',
      '[data-hr-btn]{ cursor:pointer; transition: transform .13s ease, filter .15s ease, box-shadow .15s ease; }',
      '[data-hr-btn]:hover{ transform: translate(-1px,-2px); filter: brightness(1.08); box-shadow: 0 0 0 1.7px #7C3AED, 0 8px 22px #7C3AED44; }',
      '[data-hr-btn]:active{ transform: translate(0,0) scale(.985); filter: brightness(.95); box-shadow:none; }',
      '[data-hr-btn]:has([data-hr-cta]):hover{ box-shadow:none; transform:none; filter:none; }',
      '[data-hr-cta]{ cursor:pointer; transition: color .15s ease, box-shadow .15s ease; border-radius:6px; padding:3px 7px; margin:-3px -7px; }',
      '[data-hr-cta]:hover{ box-shadow: 0 0 0 2px #8B5CF6; background: rgba(124,58,237,.14); }',
      '[data-hr-card]{ transition: transform .2s cubic-bezier(.4,0,.2,1), box-shadow .2s ease; }',
      '[data-hr-card]:hover{ transform: translateY(-3px); box-shadow: 0 0 0 1.6px #7C3AED, 0 18px 44px -14px rgba(124,58,237,.55); }',
      '[data-hr-reveal]{ opacity:0; transform:translateY(16px); transition: opacity .7s cubic-bezier(.2,.6,.2,1), transform .7s cubic-bezier(.2,.6,.2,1); }',
      '[data-hr-reveal].hr-in{ opacity:1; transform:none; }',
      'body{ transition: opacity .28s ease; }',
      'body.hr-leaving{ opacity:0; }',
      'html, body{ scroll-behavior:smooth; }',
      '#hr-bgfx{ position:fixed; inset:0; z-index:0; pointer-events:none; background:#07070C; overflow:hidden; }',
      '#hr-bgfx canvas{ position:absolute; inset:0; width:100%; height:100%; display:block; }',
      '[data-hr-menu].hr-open{ display:flex; }',
      '[data-hr-burger].hr-open{ background:#FFFFFF1F; }',
      '[data-hr-mlink]:active{ opacity:.6; }'
    ].join('\n');
    (document.head||document.documentElement).appendChild(s);
  }

  /* ---------------- i18n (RU/EN runtime switch) ---------------- */
  function getLang(){ try{ return localStorage.getItem('hr-lang')||'ru'; }catch(e){ return 'ru'; } }
  // Delegate to the single canonical translator in hr-i18n.js (always loaded before
  // this file). Was a byte-identical copy of hr-i18n's apply() — dedup'd to one source.
  function applyLang(lang){ if(window.__hrApplyI18n){ window.__hrApplyI18n(lang); } }
  window.__hrSetLang=function(l){ l=(l==='en')?'en':'ru'; try{ localStorage.setItem('hr-lang', l); }catch(e){} applyLang(l); };

  /* ---------------- navigation + buttons ---------------- */
  function fixHeader(){
    var meth=document.querySelector('[data-pencil-name="МЕТОДОЛОГИЯ"]');
    var tseny=document.querySelector('[data-pencil-name="ЦЕНЫ"]');
    if(meth && tseny){
      meth.textContent='МЕТОДОЛОГИЯ И ЦЕНЫ';
      meth.setAttribute('data-pencil-name','МЕТОДОЛОГИЯ И ЦЕНЫ');
      var dot=tseny.previousElementSibling;
      if(dot && (dot.getAttribute('data-pencil-name')||'')==='dot') dot.parentNode.removeChild(dot);
      tseny.parentNode.removeChild(tseny);
    }
    var actions=document.querySelector('[data-pencil-name="Actions"]');
    if(actions && !actions.getAttribute('data-hr-actions')){
      actions.setAttribute('data-hr-actions','1');
      while(actions.firstChild) actions.removeChild(actions.firstChild);
      var mk=function(label, filled){
        var b=document.createElement('div');
        b.setAttribute('data-pencil-name',label);
        b.style.cursor='pointer';
        if(filled){ b.className='box-border w-fit shrink-0 h-fit flex flex-row gap-0 p-[10px_15px] justify-start items-center bg-[#7C3AED] rounded-[6px]';
          b.innerHTML='<div class="text-[12.5px]/[normal] box-border text-[#FFFFFF] font-[\'Geist_Mono\',system-ui,sans-serif] font-semibold tracking-[1px] text-left [white-space:nowrap]">'+label+'</div>';
        } else { b.className='box-border w-fit shrink-0 h-fit flex flex-row gap-0 p-[9px_13px] justify-start items-center bg-[#FFFFFF12] [border:1px_solid_#FFFFFF3D] rounded-[6px]';
          b.innerHTML='<div class="text-[12.5px]/[normal] box-border text-[#F5F2EC] font-[\'Geist_Mono\',system-ui,sans-serif] font-medium tracking-[1px] text-left [white-space:nowrap]">'+label+'</div>';
        }
        return b;
      };
      actions.appendChild(mk('Открыть сервис', false));
      actions.appendChild(mk('Открыть расширение', false));
      actions.appendChild(mk('Подключить канал', true));
      var sw=document.createElement('div');
      sw.setAttribute('data-hr-lang','');
      sw.className='box-border w-fit shrink-0 h-fit flex flex-row items-center';
      sw.style.cssText='border:1px solid #FFFFFF24;border-radius:6px;overflow:hidden';
      ['ru','en'].forEach(function(lg){
        var t=document.createElement('div');
        t.setAttribute('data-hr-lang-btn',lg);
        t.textContent=lg.toUpperCase();
        t.style.cssText='padding:8px 9px;font-family:Geist Mono,monospace;font-size:11.5px;font-weight:600;letter-spacing:1px;cursor:pointer;color:#8E8A9A';
        t.addEventListener('click', function(){ window.__hrSetLang(lg); });
        sw.appendChild(t);
      });
      actions.insertBefore(sw, actions.firstChild);
    }
  }
  function wireNav(){
    var CUR=location.pathname;
    var NAV={
      'СТРИМЕРАМ':'/streamers','БРЕНДАМ':'/brands','ЗРИТЕЛЯМ':'/viewers',
      'МЕТОДОЛОГИЯ':'/methodology','ЦЕНЫ':'/methodology','МЕТОДОЛОГИЯ И ЦЕНЫ':'/methodology',
      'Стримерам':'/streamers','Брендам':'/brands','Зрителям':'/viewers',
      'Цены':'/methodology','Методология':'/methodology','Главная':'/'
    };
    window.__hrGo=function(href){
      if(!href) return;
      if(href.toLowerCase()===CUR){ window.scrollTo({top:0,behavior:'smooth'}); return; }
      document.body.classList.add('hr-leaving');
      setTimeout(function(){ location.href=href; }, 240);
    };
    $all('div,span,a,p').forEach(function(el){
      if(el.querySelector('*')) return;
      var t=(el.textContent||'').trim();
      if(NAV[t]){ el.setAttribute('data-hr-link',''); el.addEventListener('click', function(e){ if(e.metaKey||e.ctrlKey||e.shiftKey||e.altKey||e.button!==0) return; e.preventDefault(); e.stopPropagation(); window.__hrGo(NAV[t]); }); }
    });
    $all('[data-pencil-name="Wordmark"]').forEach(function(el){ el.setAttribute('data-hr-link',''); el.addEventListener('click', function(){ window.__hrGo('/'); }); });
    $all('[data-pencil-name="Войти"]').forEach(function(el){ el.setAttribute('data-hr-link',''); el.addEventListener('click', function(){ window.__hrGo('/login'); }); });

    function soon(msg){
      var t=document.createElement('div'); t.textContent=msg||'Скоро';
      t.style.cssText='position:fixed;left:50%;bottom:32px;transform:translateX(-50%);z-index:99999;'+
        'background:#FF5C8A;color:#0B0B12;font:600 15px system-ui,sans-serif;padding:12px 20px;'+
        'border-radius:999px;box-shadow:0 8px 30px rgba(0,0,0,.4);opacity:0;transition:opacity .2s;';
      document.body.appendChild(t); requestAnimationFrame(function(){ t.style.opacity='1'; });
      setTimeout(function(){ t.style.opacity='0'; setTimeout(function(){ t.remove(); },250); },2200);
    }
    var ROUND=/rounded-\[(6|8|10|12|999)px\]/;
    var CTA=/^(подключить|установить|начать|связаться|все тарифы|оформить|выбрать|как это работает|как мы измеряем|узнать|смотреть|посмотреть|открыть|запросить|войти|я бренд|я зритель|я стример|выбрать план|перейти)/i;
    $all('div').forEach(function(el){
      var c=cls(el); var purple=/bg-\[#7C3AED\]/.test(c); var txt=(el.textContent||'').trim();
      var verb=ROUND.test(c)&&CTA.test(txt)&&txt.length<=64;
      if(!purple&&!verb) return;
      if(txt.length===0||txt.length>72) return;
      if(el.querySelector('[data-hr-btn]')) return;
      el.setAttribute('data-hr-btn','');
      el.addEventListener('click', function(e){
        e.stopPropagation();
        var s=txt.toLowerCase();
        // Not shipped yet → honest "coming soon", never a dead click:
        if(s.indexOf('расширение')>-1) return soon('Расширение скоро появится в Chrome Web Store');
        if(s.indexOf('биржу')>-1||s.indexOf('биржа')>-1) return soon('Биржа скоро откроется');
        var dest;
        if(s.indexOf('открыть сервис')>-1) dest='/app/home';        // viewer dashboard (gates to login)
        else if(s.indexOf('подключить')>-1) dest='/app/channel';    // streamer dashboard (gates to login)
        else if(s.indexOf('я бренд')>-1) dest='/brands';
        else if(s.indexOf('я зритель')>-1) dest='/viewers';
        else if(s.indexOf('я стример')>-1) dest='/streamers';
        else if(s.indexOf('связаться')>-1) dest='/brands';
        else dest='/methodology'; // pricing / methodology / how-it-works + fallback
        window.__hrGo(dest);
      });
    });
  }
  /* mobile burger menu (header is responsive: nav/actions collapse below lg) */
  function wireMobileNav(){
    var burger=$('[data-hr-burger]'), menu=$('[data-hr-menu]');
    if(burger && menu && !burger.__hrw){
      burger.__hrw=1;
      burger.addEventListener('click', function(e){ e.stopPropagation(); var open=menu.classList.toggle('hr-open'); burger.classList.toggle('hr-open', open); });
      menu.addEventListener('click', function(e){ if(e.target.closest('[data-hr-mlink],[data-pencil-name]')){ menu.classList.remove('hr-open'); burger.classList.remove('hr-open'); } });
      document.addEventListener('click', function(e){ if(!menu.contains(e.target) && !burger.contains(e.target)){ menu.classList.remove('hr-open'); burger.classList.remove('hr-open'); } });
      window.addEventListener('resize', function(){ if(window.innerWidth>=1024){ menu.classList.remove('hr-open'); burger.classList.remove('hr-open'); } });
    }
    // lang buttons baked into the mobile menu need their own click wiring
    $all('[data-hr-lang-btn]').forEach(function(b){ if(b.__hrl) return; b.__hrl=1; b.addEventListener('click', function(e){ e.stopPropagation(); window.__hrSetLang(b.getAttribute('data-hr-lang-btn')); }); });
  }

  /* ---------------- card hover ---------------- */
  function tagCards(root){
    var RND=/rounded-\[(10|12|14|16|18|20|24)px\]/;
    $all('div', root).forEach(function(el){
      if(!RND.test(cls(el))) return;
      if(el.hasAttribute('data-hr-card')) return;
      var r=el.getBoundingClientRect();
      if(r.width<150||r.width>760||r.height<90||r.height>640) return;
      var bg=getComputedStyle(el).backgroundColor||''; var m=bg.match(/rgba?\((\d+),\s*(\d+),\s*(\d+)(?:,\s*([\d.]+))?/);
      if(!m) return; if(m[4]!==undefined && parseFloat(m[4])<0.04) return;     // essentially transparent
      if(el.querySelector('[data-hr-card]')) return;                            // outermost rounded card only
      el.setAttribute('data-hr-card','');
    });
  }

  /* ---------------- reveal on scroll + count-up ---------------- */
  function nbsp(n){ n=Math.round(n); var s=String(Math.abs(n)),o='',c=0; for(var i=s.length-1;i>=0;i--){ o=s[i]+o; if(++c%3===0&&i>0) o='\u202F'+o; } return (n<0?'-':'')+o; }
  function fmtLike(sample,val){
    var pre=(sample.match(/^[~$]/)||[''])[0];
    var suf=(sample.match(/[%x×+]$/)||[''])[0];
    var sep=sample.indexOf('\u202F')>-1?'\u202F':(/\d \d/.test(sample)?' ':(sample.indexOf(',')>-1?',':''));
    var n=Math.round(val),s=String(n),o='',c=0;
    if(sep){ for(var i=s.length-1;i>=0;i--){ o=s[i]+o; if(++c%3===0&&i>0) o=sep+o; } } else o=s;
    return pre+o+suf;
  }
  function countUp(el){
    if(el.__cu) return; var sample=(el.textContent||'').trim();
    if(sample.indexOf('.')>-1) return;                       // skip decimals
    var digits=sample.replace(/[^\d]/g,''); if(!digits) return;
    var to=parseInt(digits,10); if(!isFinite(to)||to<10||to>9999999) return;
    el.__cu=1; var st=Date.now(), dur=1100;
    var iv=setInterval(function(){ var p=Math.min(1,(Date.now()-st)/dur), e=1-Math.pow(1-p,3); el.textContent=fmtLike(sample, to*e); if(p>=1) clearInterval(iv); }, 16);
  }
  function setupReveal(root){
    var secs=$all(':scope > *', root);
    // also reveal the meaningful sub-sections one level down for longer pages
    if(secs.length<=2){ var more=[]; secs.forEach(function(s){ more=more.concat($all(':scope > *', s)); }); if(more.length) secs=more; }
    var H=window.innerHeight||800;
    var io=new IntersectionObserver(function(ents){
      ents.forEach(function(en){ if(!en.isIntersecting) return; var t=en.target;
        t.classList.add('hr-in');
        $all('div,span,p', t).forEach(function(le){ if(le.children.length) return;
          var f=parseFloat(getComputedStyle(le).fontSize)||0; if(f<34) return;
          var tx=(le.textContent||'').trim(); if(/^[~$]?\d[\d\u202F .,]*[%x×+]?$/.test(tx)) countUp(le);
        });
        io.unobserve(t);
      });
    }, {threshold:0.12, rootMargin:'0px 0px -8% 0px'});
    secs.forEach(function(s){ var r=s.getBoundingClientRect(); if(r.height<24) return;
      if(r.top>H*0.82){ s.setAttribute('data-hr-reveal',''); } else { s.classList.add('hr-in'); }
      io.observe(s);
    });
  }

  /* ---------------- animated dot background ---------------- */
  var __bgInit=false;
  function bg(){
    var root = ROOT_SEL ? $(ROOT_SEL) : null;
    if(!root){ root = $all('body > div[data-pencil-name]')[0] || document.body; }
    var fx=document.getElementById('hr-bgfx');
    if(!fx){ fx=document.createElement('div'); fx.id='hr-bgfx'; document.body.insertBefore(fx, document.body.firstChild); }
    root.style.position='relative'; root.style.zIndex='1'; root.style.background='transparent';
    var cleared=0;
    $all('div', root).forEach(function(el){
      var r=el.getBoundingClientRect(); if(r.width<860||r.height<120) return;
      var m=(getComputedStyle(el).backgroundColor||'').match(/rgba?\((\d+),\s*(\d+),\s*(\d+)/); if(!m) return;
      if(+m[1]<14 && +m[2]<14 && +m[3]<22){ el.style.background='transparent'; cleared++; }
    });
    if(!__bgInit){ __bgInit=true; initBgCanvas(fx); }
    return cleared>0;
  }
  var MARK=[
    "m24.7 4.5 0.7 3.2c1 0.3 2 1.2 2 2.3 0 1.3-1.1 2.5-2.6 2.5-1.2 0-2.5-1-2.5-2.5 0-0.8 0.4-1.5 1.1-2l-0.7-3.2c-2.7 0.5-4.6 2.8-4.6 5.6 0 3.3 2.6 6.1 6 6.1 3.2 0 6-2.5 6.1-6 0.1-2.9-2.3-5.7-5.5-6z",
    "m22.4 2.6 1.9-0.4 0.4 2.2c-0.6-0.1-1.3 0-1.9 0.1l-0.4-1.9z",
    "m33.6 18.6c-1.4-1.2-4.8-2.6-7.4-0.6-2.6 2.2-4.2 5.8-4.6 12.3h19.3c-1.5-4.8-5.6-9.9-7.3-11.7z",
    "m14.7 26.2c-1.6 0.2-3.2 1.3-4 2.9h-6.4c-0.7 0-1.4-0.2-1-1.5 0.6-2.3 3.1-8.7 3.8-10.8 0.2-0.6 0.5-0.8 0.7-0.8 0.9 4 2.1 8.3 2.8 9l1.6-0.4-3.9-20-1.7 0.4c-0.1 2.8 0.4 6.6 1 9.7-0.7 0.2-1.2 0.6-1.6 1.3-0.9 1.9-3.8 9-4.1 11.7-0.3 1.2 0.3 2.6 2 2.6h15.1c0-2.3-2-4.1-4.3-4.1z"
  ];
  function sm(t){ t=t<0?0:(t>1?1:t); return t*t*(3-2*t); }

  function initBgCanvas(fx){
    var cv=document.createElement('canvas'); fx.appendChild(cv);
    try{ document.querySelectorAll('[data-pencil-name="Dot BG"],[data-pencil-name="Dots BG"],[data-pencil-name="Dots"],[data-pencil-name="Particles"]').forEach(function(e){ e.style.display='none'; }); }catch(e){}
    var ctx=cv.getContext('2d'); var DPR=Math.min(2, window.devicePixelRatio||1);
    var W=0,H=0,N=1900,dots=[],free=[];
    // scene list: each = {at, kind, style}. kind = 'logo' | 'word:XXX' | a shape key.
    var SCN=(CFG.scenes && CFG.scenes.length) ? CFG.scenes.slice() : [{at:0.5, kind: SHAPE || ('word:'+WORD)}];
    SCN.sort(function(a,b){ return a.at-b.at; });

    function drawLogo(ox,gx,gy){
      var fs=Math.max(56, W*(CFG.logoScale||0.115));
      ox.textBaseline='middle'; ox.textAlign='left'; ox.font='800 '+fs+'px "Playfair Display", Georgia, serif';
      var textW=ox.measureText('HimRate').width, markH=fs*1.2, markW=markH*(42/38), gap=fs*0.3;
      var totalW=markW+gap+textW, sx=Math.round((W-totalW)/2);
      try{ ox.save(); ox.translate(sx, gy-markH/2); ox.scale(markW/42, markH/38); for(var p=0;p<MARK.length;p++) ox.fill(new Path2D(MARK[p])); ox.restore(); }catch(e){}
      ox.fillText('HimRate', sx+markW+gap, gy);
    }
    function drawKind(ox,kind){
      var gx=W/2, gy=H*0.5, S=Math.min(W*0.46, 540);
      ox.fillStyle='#fff'; ox.strokeStyle='#fff';
      if(kind==='logo'){ drawLogo(ox,gx,gy); return; }
      if(kind.indexOf('word:')===0){ var w=kind.slice(5); var fs=Math.max(64,Math.min(W*0.17,236)); ox.textAlign='center'; ox.textBaseline='middle'; ox.font='800 '+fs+'px "Space Grotesk","Playfair Display",Georgia,sans-serif'; ox.fillText(w,gx,gy); return; }
      if(SHAPES[kind]){ SHAPES[kind](ox,gx,gy,S); return; }
      ox.textAlign='center'; ox.textBaseline='middle'; ox.font='800 160px sans-serif'; ox.fillText(kind,gx,gy);
    }
    function sampleKind(kind){
      if(kind==='scatter'){ var o=[]; for(var q=0;q<N;q++) o.push([Math.random()*W, Math.random()*H]); return {pts:o, cx:W/2, cy:H/2}; }
      var oc=document.createElement('canvas'); oc.width=W; oc.height=H; var ox=oc.getContext('2d');
      drawKind(ox,kind);
      var d; try{ d=ox.getImageData(0,0,W,H).data; }catch(e){ return {pts:[],cx:W/2,cy:H/2}; }
      var pts=[], step=Math.max(4, Math.round(Math.min(W,H)/170));
      for(var yy=0;yy<H;yy+=step){ for(var xx=0;xx<W;xx+=step){ if(d[(yy*W+xx)*4+3]>128) pts.push([xx,yy]); } }
      var cx=0,cy=0,i; for(i=0;i<pts.length;i++){ cx+=pts[i][0]; cy+=pts[i][1]; } if(pts.length){ cx/=pts.length; cy/=pts.length; }
      pts.sort(function(a,b){ return Math.atan2(a[1]-cy,a[0]-cx)-Math.atan2(b[1]-cy,b[0]-cx); });
      var out=[]; if(pts.length){ for(i=0;i<N;i++) out.push(pts[Math.floor(i*pts.length/N)]); }
      else { for(i=0;i<N;i++) out.push([W/2,H/2]); }
      return {pts:out, cx:cx||W/2, cy:cy||H/2};
    }
    var LOGO=null;
    function build(){
      W=window.innerWidth||1440; H=window.innerHeight||800;
      cv.width=W*DPR; cv.height=H*DPR; cv.style.width=W+'px'; cv.style.height=H+'px';
      ctx.setTransform(DPR,0,0,DPR,0,0);
      LOGO=sampleKind('logo');
      var jit = CFG.mirage? 14 : 4;
      var prev=dots; dots=[];
      for(var i=0;i<N;i++){ var p=prev[i];
        dots.push({ hx:p?p.hx:Math.random()*W, hy:p?p.hy:Math.random()*H, ph:p?p.ph:Math.random()*6.2832,
          sp:p?p.sp:(0.32+Math.random()*0.8), r:p?p.r:(0.8+Math.random()*1.3), dir:p?p.dir:(Math.random()<0.5?-1:1),
          jx:p?p.jx:((Math.random()*2-1)*jit), jy:p?p.jy:((Math.random()*2-1)*jit),
          col:p?p.col:(COLS[Math.random()<0.5?0:1]) }); }
      if(free.length===0){ for(var j=0;j<2700;j++){ free.push({ hx:Math.random()*W, hy:Math.random()*H, ph:Math.random()*6.2832, sp:0.22+Math.random()*0.7, r:0.7+Math.random()*1.2, col:(COLS[Math.random()<0.5?0:1]) }); }
      } else { for(var f2=0;f2<free.length;f2++){ if(free[f2].hx>W) free[f2].hx=Math.random()*W; if(free[f2].hy>H) free[f2].hy=Math.random()*H; } }
    }
    function morph(x0,y0,x1,y1,e,style,dot,pvx,pvy){
      if(style==='stream'){ var lt=sm((e-(x1/(W||1))*0.45)/0.55); return [x0+(x1-x0)*lt, y0+(y1-y0)*lt]; }
      var x=x0+(x1-x0)*e, y=y0+(y1-y0)*e;
      if(style==='swirl'){ var vx=-(y1-y0), vy=(x1-x0), vl=Math.sqrt(vx*vx+vy*vy)||1, sw=Math.sin(e*Math.PI)*52*dot.dir; return [x+vx/vl*sw, y+vy/vl*sw]; }
      if(style==='orbit'){ var a=Math.sin(e*Math.PI)*0.7*dot.dir, dx=x-pvx, dy=y-pvy, ca=Math.cos(a), sa=Math.sin(a); return [pvx+dx*ca-dy*sa, pvy+dx*sa+dy*ca]; }
      return [x,y];
    }
    function frame(){
      var y=window.scrollY||document.documentElement.scrollTop||0;
      var maxH=Math.max(1,(document.body.scrollHeight||document.documentElement.scrollHeight)-window.innerHeight);
      var fr=Math.max(0,Math.min(1,y/maxH));
      var ats=(CFG.assembleAts && CFG.assembleAts.length)?CFG.assembleAts:[(CFG.assembleAt!=null?CFG.assembleAt:0.5)];
      var halfW=(CFG.assembleWidth!=null?CFG.assembleWidth:0.16);
      var af=0;
      for(var ai=0;ai<ats.length;ai++){ var dd2=Math.abs(fr-ats[ai])/halfW; if(dd2<1){ var a2=sm(1-dd2); if(a2>af) af=a2; } }
      var mirage=!!CFG.mirage;
      var time=Date.now()*0.001;
      var pvx=W/2, pvy=H*0.46;
      ctx.clearRect(0,0,W,H);
      for(var f=0; f<free.length; f++){ var ff=free[f];
        var fax=ff.hx+Math.sin(time*ff.sp+ff.ph)*32, fay=ff.hy+Math.cos(time*ff.sp*0.9+ff.ph)*32;
        ctx.beginPath(); ctx.fillStyle='rgba('+ff.col+',0.154)'; ctx.arc(fax,fay,ff.r,0,6.2832); ctx.fill(); }
      var amb=(1-af)*22+3;
      var maxA=mirage?0.238:0.546;
      for(var i=0;i<dots.length;i++){ var dd=dots[i];
        var ox2=Math.sin(time*dd.sp+dd.ph)*amb, oy2=Math.cos(time*dd.sp*0.9+dd.ph)*amb;
        var x0=dd.hx, y0=dd.hy, x1=LOGO.pts[i][0]+dd.jx, y1=LOGO.pts[i][1]+dd.jy;
        var pp=morph(x0,y0,x1,y1,af,'swirl',dd,pvx,pvy);
        var a=0.084+af*(maxA-0.084);
        ctx.beginPath(); ctx.fillStyle='rgba('+dd.col+','+a.toFixed(3)+')'; ctx.arc(pp[0]+ox2, pp[1]+oy2, dd.r+af*0.5, 0, 6.2832); ctx.fill(); }
    }
    build();
    var rt; window.addEventListener('resize', function(){ clearTimeout(rt); rt=setTimeout(build,180); });
    if(fx.__loop) clearInterval(fx.__loop); fx.__loop=setInterval(frame, 33);
  }

  /* ---------------- boot ---------------- */
  function init(){
    injectCSS();
    fixHeader();
    wireNav();
    /* burger menu wired by landing/mobile-nav.js (shared across all pages) */
    applyLang(getLang());
    setTimeout(function(){ applyLang(getLang()); }, 1400);
    var root = ROOT_SEL ? $(ROOT_SEL) : ($all('body > div[data-pencil-name]')[0]||document.body);
    var tries=0;
    (function poll(){ var ok=bg(); tagCards(root); if(ok||tries>40) return; tries++; setTimeout(poll,200); })();
    setupReveal(root);
    setTimeout(function(){ tagCards(root); }, 900);
  }
  if(document.readyState==='complete'||document.readyState==='interactive') setTimeout(init,300);
  else window.addEventListener('DOMContentLoaded', function(){ setTimeout(init,300); });
})();
