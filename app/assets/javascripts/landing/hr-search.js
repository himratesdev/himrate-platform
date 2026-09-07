// Shared channel search box — the product had NO way to type a nickname and find a channel.
// Injected on the surfaces that promise search (streamer search, blogger search) and wired to
// GET /api/v1/search, which matches BOTH the Twitch login/name and linked social handles
// (Telegram/YouTube/TikTok/VK), so «@DearHellGirl из телеги» lands on the right streamer.
// CSP-safe external asset, no eval. Exposes window.hrMountSearch(options) for page scripts.
(function () {
  "use strict";

  var PREFIX = (window.location.pathname === "/app" || window.location.pathname.indexOf("/app/") === 0) ? "/app" : "";
  function appPath(p) { return PREFIX + p; }

  var PLATFORM_RU = {
    twitch: "ник на Twitch", telegram: "Telegram", youtube: "YouTube", tiktok: "TikTok",
    vk: "VK", instagram: "Instagram", boosty: "Boosty", discord: "Discord"
  };

  function el(tag, css, text) {
    var n = document.createElement(tag);
    if (css) n.style.cssText = css;
    if (text != null) n.textContent = text;
    return n;
  }

  // options: { mount: HTMLElement, placeholder: string, onPick: function(row) }
  window.hrMountSearch = function (options) {
    var mount = options && options.mount;
    if (!mount) return null;

    var wrap = el("div", "position:relative;width:100%;max-width:420px;font-family:Inter,system-ui,sans-serif;");
    var input = document.createElement("input");
    input.type = "text";
    input.placeholder = options.placeholder || "Поиск по нику, Telegram, YouTube…";
    input.setAttribute("data-pencil-name", "Search Input");
    input.style.cssText = "box-sizing:border-box;width:100%;padding:11px 14px;background:#141419;" +
      "color:#F4F4F7;font-size:13px;border:1px solid #25252F;border-radius:10px;outline:none;";
    wrap.appendChild(input);

    var list = el("div", "position:absolute;left:0;right:0;top:46px;z-index:50;background:#101018;" +
      "border:1px solid #25252F;border-radius:12px;overflow:hidden;display:none;" +
      "box-shadow:0 12px 32px rgba(0,0,0,.55);max-height:320px;overflow-y:auto;");
    wrap.appendChild(list);
    mount.appendChild(wrap);

    function close() { list.style.display = "none"; }
    document.addEventListener("click", function (e) { if (!wrap.contains(e.target)) close(); }, true);

    function note(text) {
      list.textContent = "";
      list.appendChild(el("div", "padding:12px 14px;font-size:12.5px;color:#8E8A9A;", text));
      list.style.display = "block";
    }

    function render(rows, query) {
      list.textContent = "";
      if (!rows.length) { note("Ничего не нашлось по «" + query + "»"); return; }
      rows.forEach(function (row) {
        var item = el("div", "display:flex;align-items:center;gap:10px;padding:10px 14px;cursor:pointer;");
        item.addEventListener("mouseenter", function () { item.style.background = "#19152E"; });
        item.addEventListener("mouseleave", function () { item.style.background = ""; });

        var av = el("div", "width:28px;height:28px;border-radius:99px;background:#1E1838;color:#7B5CFA;" +
          "display:flex;align-items:center;justify-content:center;font-size:12px;font-weight:700;flex:0 0 auto;",
          (row.display_name || row.login || "?").slice(0, 1).toUpperCase());
        if (row.avatar_url) {
          av.textContent = "";
          av.style.background = "#1E1838 center/cover url('" + row.avatar_url.replace(/'/g, "") + "')";
        }
        item.appendChild(av);

        var col = el("div", "min-width:0;flex:1 1 auto;");
        col.appendChild(el("div", "font-size:13px;color:#F4F4F7;font-weight:600;white-space:nowrap;" +
          "overflow:hidden;text-overflow:ellipsis;", row.display_name || row.login));
        // Say WHY it matched — a Telegram hit on a different nickname would otherwise look random.
        var why = PLATFORM_RU[row.matched_on] || row.matched_on;
        var sub = row.matched_on === "twitch"
          ? "twitch.tv/" + row.login
          : why + ": " + (row.matched_value || "") + " · twitch.tv/" + row.login;
        col.appendChild(el("div", "font-size:11px;color:#5E5E6B;white-space:nowrap;overflow:hidden;" +
          "text-overflow:ellipsis;", sub));
        item.appendChild(col);

        if (row.followers != null) {
          item.appendChild(el("div", "font-size:11px;color:#8E8A9A;flex:0 0 auto;",
            row.followers.toLocaleString("ru-RU") + " фолловеров"));
        }

        item.addEventListener("click", function () {
          close();
          if (options.onPick) options.onPick(row);
          else window.location.href = appPath("/streamers/" + encodeURIComponent(row.login));
        });
        list.appendChild(item);
      });
      list.style.display = "block";
    }

    var timer = null, lastQuery = "";
    function search() {
      var q = input.value.trim();
      if (q.length < 2) { close(); return; }
      lastQuery = q;
      fetch("/api/v1/search?q=" + encodeURIComponent(q), {
        headers: { Accept: "application/json" }, credentials: "same-origin"
      })
        .then(function (r) { return r.ok ? r.json() : Promise.reject(r.status); })
        .then(function (body) {
          if (input.value.trim() !== lastQuery) return; // a newer keystroke already won
          render((body && body.data) || [], lastQuery);
        })
        .catch(function () { note("Поиск временно недоступен"); });
    }

    input.addEventListener("input", function () {
      clearTimeout(timer);
      timer = setTimeout(search, 220); // debounce: type-ahead without hammering the API
    });
    input.addEventListener("keydown", function (e) {
      if (e.key === "Enter") { clearTimeout(timer); search(); }
      if (e.key === "Escape") close();
    });

    return { input: input, close: close };
  };
})();
