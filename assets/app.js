/* Progressive enhancement only: the page is complete without this file. */
(function () {
  "use strict";

  var reduced = window.matchMedia && window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  var saveData = navigator.connection && navigator.connection.saveData;

  /* copy buttons on every <pre data-copy> */
  function copyText(text) {
    if (navigator.clipboard && window.isSecureContext) {
      return navigator.clipboard.writeText(text);
    }
    return new Promise(function (resolve, reject) {
      var ta = document.createElement("textarea");
      ta.value = text;
      ta.setAttribute("readonly", "");
      ta.className = "vh";
      document.body.appendChild(ta);
      ta.select();
      var ok = false;
      try { ok = document.execCommand("copy"); } catch (err) { ok = false; }
      document.body.removeChild(ta);
      ok ? resolve() : reject(new Error("copy failed"));
    });
  }

  var live = document.createElement("div");
  live.className = "vh";
  live.setAttribute("role", "status");
  live.setAttribute("aria-live", "polite");
  document.body.appendChild(live);

  Array.prototype.forEach.call(document.querySelectorAll("pre[data-copy]"), function (pre) {
    var btn = document.createElement("button");
    btn.type = "button";
    btn.className = "copy";
    btn.innerHTML = '<svg class="icon" aria-hidden="true" focusable="false"><use href="#i-copy"></use></svg><span>Copy</span>';
    var label = btn.querySelector("span");
    var use = btn.querySelector("use");
    var timer = 0;
    btn.addEventListener("click", function () {
      copyText(pre.textContent.replace(/\s+$/, "")).then(function () {
        label.textContent = "Copied";
        use.setAttribute("href", "#i-tick");
        btn.setAttribute("data-state", "done");
        live.textContent = "Copied to the clipboard";
      }, function () {
        label.textContent = "Press Ctrl+C";
        live.textContent = "Copy failed: select the text and copy it by hand";
        var sel = window.getSelection();
        var range = document.createRange();
        range.selectNodeContents(pre);
        sel.removeAllRanges();
        sel.addRange(range);
      });
      window.clearTimeout(timer);
      timer = window.setTimeout(function () {
        label.textContent = "Copy";
        use.setAttribute("href", "#i-copy");
        btn.removeAttribute("data-state");
        live.textContent = "";
      }, 2200);
    });
    var box = pre.parentNode;
    if (box.classList.contains("install-box")) {
      box.querySelector(".label").appendChild(btn);
    } else {
      btn.className = "copy copy-float";
      box.classList.add("has-copy");
      box.appendChild(btn);
    }
  });

  /* the CSS-only menu closes after a choice */
  var toggle = document.getElementById("nav-toggle");
  var nav = document.getElementById("site-nav");
  if (toggle && nav) {
    nav.addEventListener("click", function (ev) {
      if (ev.target.closest && ev.target.closest("a")) { toggle.checked = false; }
    });
    document.addEventListener("keydown", function (ev) {
      if (ev.key === "Escape" && toggle.checked) { toggle.checked = false; toggle.focus(); }
    });
  }

  /* active section in the nav */
  if ("IntersectionObserver" in window && nav) {
    var links = {};
    Array.prototype.forEach.call(nav.querySelectorAll('a[href^="#"]'), function (a) {
      links[a.getAttribute("href").slice(1)] = a;
    });
    var visible = {};
    var order = Object.keys(links);
    var update = function () {
      var current = null;
      order.forEach(function (id) { if (visible[id]) { current = id; } });
      order.forEach(function (id) {
        if (id === current) { links[id].setAttribute("aria-current", "true"); }
        else { links[id].removeAttribute("aria-current"); }
      });
    };
    var spy = new IntersectionObserver(function (entries) {
      entries.forEach(function (en) { visible[en.target.id] = en.isIntersecting; });
      update();
    }, { rootMargin: "-30% 0px -60% 0px" });
    order.forEach(function (id) {
      var sec = document.getElementById(id);
      if (sec) { spy.observe(sec); }
    });
  }

  /* recordings: load and play only while on screen, never with reduced motion */
  var videos = Array.prototype.slice.call(document.querySelectorAll("video"));
  if (videos.length && "IntersectionObserver" in window && !reduced && !saveData) {
    var paused = new WeakSet(); /* videos the visitor stopped by hand */
    var byScript = new WeakSet();
    videos.forEach(function (v) {
      v.addEventListener("pause", function () {
        if (byScript.has(v)) { byScript.delete(v); } else if (!v.ended) { paused.add(v); }
      });
    });
    var player = new IntersectionObserver(function (entries) {
      entries.forEach(function (en) {
        var v = en.target;
        if (en.isIntersecting) {
          if (!paused.has(v)) {
            var p = v.play();
            if (p && p.catch) { p.catch(function () {}); }
          }
        } else if (!v.paused) {
          byScript.add(v);
          v.pause();
        }
      });
    }, { threshold: 0.6 });
    videos.forEach(function (v) { player.observe(v); });
  }
})();
