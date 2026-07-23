/*
 * Light/dark theme toggle addon.
 * Persists the choice in localStorage and defaults to dark (AMOLED-friendly).
 * Works alongside the app's bundled dark :root palette; light is applied by
 * setting data-theme="light" on <html>, which activates theme.css overrides.
 */
(function () {
  "use strict";

  var KEY = "theme";
  var root = document.documentElement;

  var SUN = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="4"></circle><path d="M12 2v2M12 20v2M4.93 4.93l1.41 1.41M17.66 17.66l1.41 1.41M2 12h2M20 12h2M6.34 17.66l-1.41 1.41M19.07 4.93l-1.41 1.41"></path></svg>';
  var MOON = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M21 12.79A9 9 0 1 1 11.21 3 7 7 0 0 0 21 12.79z"></path></svg>';

  function readTheme() {
    var v;
    try { v = localStorage.getItem(KEY); } catch (e) { v = null; }
    return v === "light" ? "light" : "dark";
  }

  function applyTheme(theme) {
    root.dataset.theme = theme;
  }

  function updateButton(btn, theme) {
    // Show the icon of the mode you would switch TO.
    btn.innerHTML = theme === "light" ? MOON : SUN;
    btn.setAttribute(
      "aria-label",
      theme === "light" ? "切換至深色主題" : "切換至淺色主題"
    );
    btn.setAttribute("title", theme === "light" ? "切換至深色主題" : "切換至淺色主題");
  }

  function createToggle() {
    if (document.querySelector(".dnscrypt-theme-toggle")) return;
    var current = readTheme();
    applyTheme(current);

    var btn = document.createElement("button");
    btn.type = "button";
    btn.className = "dnscrypt-theme-toggle";
    updateButton(btn, current);

    btn.addEventListener("click", function () {
      var next = (root.dataset.theme === "light") ? "dark" : "light";
      applyTheme(next);
      try { localStorage.setItem(KEY, next); } catch (e) { /* storage unavailable */ }
      updateButton(btn, next);
    });

    document.body.appendChild(btn);
  }

  // Apply the stored theme as early as possible to avoid a flash.
  applyTheme(readTheme());

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", createToggle);
  } else {
    createToggle();
  }
})();
