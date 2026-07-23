/*
 * DNS Leak Test addon.
 * Injects a "洩漏檢測" button into the DNS test card once the React app has
 * mounted, runs `dnscrypt-control.sh leak-test` via the KernelSU/APatch WebUI
 * exec bridge, and renders the verdict. Fully offline; no remote resources.
 */
(function () {
  "use strict";

  var MODID = "dnscrypt-proxy-root";
  var CONTROL = "/data/adb/modules/" + MODID + "/scripts/dnscrypt-control.sh";
  var MARK = "data-leaktest-injected";

  // Run a shell command through the WebUI bridge. Supports both the legacy
  // synchronous ksu.exec (returns stdout string) and the callback form
  // ksu.exec(cmd, opts, callbackName) used by KernelSU WebUI-X / APatch.
  function execCmd(cmd) {
    return new Promise(function (resolve) {
      if (!(typeof window !== "undefined" && window.ksu && typeof window.ksu.exec === "function")) {
        resolve({ errno: 1, stdout: "", stderr: "no ksu bridge" });
        return;
      }
      var settled = false;
      var cbName = "dnscryptLeakCb_" + Date.now() + "_" + Math.floor(Math.random() * 1e6);
      window[cbName] = function (errno, stdout, stderr) {
        if (settled) return;
        settled = true;
        try { delete window[cbName]; } catch (e) { window[cbName] = undefined; }
        resolve({ errno: errno, stdout: stdout || "", stderr: stderr || "" });
      };
      try {
        var ret = window.ksu.exec(cmd, "{}", cbName);
        if (typeof ret === "string") {
          if (!settled) {
            settled = true;
            try { delete window[cbName]; } catch (e) { window[cbName] = undefined; }
            resolve({ errno: 0, stdout: ret, stderr: "" });
          }
        }
      } catch (err) {
        if (settled) return;
        try {
          var out = window.ksu.exec(cmd);
          settled = true;
          resolve({ errno: 0, stdout: typeof out === "string" ? out : "", stderr: "" });
        } catch (e2) {
          settled = true;
          resolve({ errno: 1, stdout: "", stderr: String(e2) });
        }
      }
    });
  }

  var VERDICTS = {
    protected: { color: "#22c55e", text: "未檢測到洩漏，DNS 流量已受保護" },
    partial: { color: "#eab308", text: "檢測到部分洩漏" },
    leaking: { color: "#ef4444", text: "DNS 流量正在洩漏！未經過 dnscrypt-proxy" }
  };

  function buildUI() {
    var wrap = document.createElement("div");
    wrap.className = "dnscrypt-leaktest";

    var btn = document.createElement("button");
    btn.type = "button";
    btn.className = "dnscrypt-leaktest-btn";
    btn.textContent = "洩漏檢測";

    var result = document.createElement("div");
    result.className = "dnscrypt-leaktest-result";
    result.style.display = "none";

    wrap.appendChild(btn);
    wrap.appendChild(result);

    btn.addEventListener("click", function () {
      if (btn.disabled) return;
      btn.disabled = true;
      btn.textContent = "檢測中...";
      result.style.display = "block";
      result.style.color = "";
      result.textContent = "正在檢測 DNS 洩漏，請稍候...";

      execCmd("sh " + CONTROL + " leak-test").then(function (res) {
        var data = null;
        try { data = JSON.parse((res.stdout || "").trim()); } catch (e) { data = null; }

        if (!data || !data.status) {
          result.style.color = VERDICTS.leaking.color;
          result.textContent = "檢測失敗，無法解析結果";
        } else if (data.status === "error" && data.reason === "query_log_disabled") {
          result.style.color = VERDICTS.partial.color;
          result.textContent = "查詢日誌 (query_log) 未啟用，無法進行洩漏檢測";
        } else {
          var v = VERDICTS[data.status] || VERDICTS.leaking;
          result.style.color = v.color;
          var detail = "";
          if (typeof data.matched === "number" && typeof data.tested === "number") {
            detail = "（" + data.matched + "/" + data.tested + " 命中）";
          }
          result.textContent = v.text + detail;
        }
      }).catch(function () {
        result.style.color = VERDICTS.leaking.color;
        result.textContent = "檢測失敗";
      }).then(function () {
        btn.disabled = false;
        btn.textContent = "洩漏檢測";
      });
    });

    return wrap;
  }

  // Find the DNS test card. The domain input placeholder contains "google.com"
  // in every supported locale, which makes it a stable anchor.
  function findAnchor() {
    var inputs = document.querySelectorAll("input[placeholder]");
    for (var i = 0; i < inputs.length; i++) {
      var ph = inputs[i].getAttribute("placeholder") || "";
      if (ph.indexOf("google.com") !== -1) {
        return inputs[i];
      }
    }
    return null;
  }

  function tryInject() {
    var input = findAnchor();
    if (!input) return false;
    // Walk up to a reasonable container to append after.
    var container = input.closest("form") || input.parentElement;
    if (!container) return false;
    var host = container.parentElement || container;
    if (host.querySelector("[" + MARK + "]")) return true;

    var ui = buildUI();
    ui.setAttribute(MARK, "1");
    host.appendChild(ui);
    return true;
  }

  function start() {
    if (tryInject()) return;
    var observer = new MutationObserver(function () {
      if (tryInject()) {
        // Keep observing: React may unmount/remount the tab, and the marker
        // check keeps injection idempotent.
      }
    });
    observer.observe(document.body, { childList: true, subtree: true });
    // Safety net in case mutations are missed.
    var tries = 0;
    var poll = setInterval(function () {
      tries++;
      if (tryInject() || tries > 60) clearInterval(poll);
    }, 1000);
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", start);
  } else {
    start();
  }
})();
