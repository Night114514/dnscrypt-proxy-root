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
      var timer = null;
      function cleanup() {
        if (timer !== null) clearTimeout(timer);
        try { delete window[cbName]; } catch (e) { window[cbName] = undefined; }
      }
      function finish(result) {
        if (settled) return;
        settled = true;
        cleanup();
        resolve(result);
      }
      window[cbName] = function (errno, stdout, stderr) {
        var code = Number(errno);
        finish({ errno: isFinite(code) ? code : 1, stdout: stdout || "", stderr: stderr || "" });
      };
      timer = setTimeout(function () {
        finish({ errno: 124, stdout: "", stderr: "command timed out" });
      }, 30000);
      try {
        var ret = window.ksu.exec(cmd, "{}", cbName);
        if (typeof ret === "string") {
          finish({ errno: 0, stdout: ret, stderr: "" });
        }
      } catch (err) {
        if (settled) return;
        try {
          var token = "__DPR_LEAK_EXIT_91f24c__";
          var wrapped = "{ __dpr_err=$( ( " + cmd + " ) 2>&1 1>&3); " +
            "__dpr_rc=$?; if [ \"$__dpr_rc\" -ne 0 ] && [ -n \"$__dpr_err\" ]; " +
            "then printf '\\n%s' \"$__dpr_err\"; fi; printf '" + token + "%s' \"$__dpr_rc\"; } 3>&1";
          var out = window.ksu.exec(wrapped);
          if (typeof out !== "string") throw new Error("legacy exec returned no output");
          var marker = out.lastIndexOf(token);
          if (marker < 0) throw new Error("legacy exec returned no status");
          var statusText = out.slice(marker + token.length).trim();
          if (!/^[0-9]+$/.test(statusText)) throw new Error("legacy exec returned invalid status");
          finish({ errno: Number(statusText), stdout: out.slice(0, marker), stderr: "" });
        } catch (e2) {
          finish({ errno: 1, stdout: "", stderr: String(e2) });
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
        if (Number(res.errno) !== 0) {
          throw new Error(res.stderr || res.stdout || "leak test command failed");
        }
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
