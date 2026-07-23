# DNSCrypt Proxy Root WebUI 模組

[English](README.md) | [繁體中文](README.zh-TW.md) | [简体中文](README.zh-CN.md)

一個 systemless 的 Magisk/KernelSU/APatch 模組，在已 root 的 Android 裝置上執行 **dnscrypt-proxy**，具備：

- **Systemless 加密 DNS**：透過 dnscrypt-proxy（DNSCrypt / DoH）
- **相容 Magisk、KernelSU 與 APatch**
- **自動 DNS 重導向**：透過 iptables DNAT 覆蓋所有 App（透明代理，無需逐一設定）
- **IPv6 DNS 洩漏防護**：以 ip6tables 阻擋 IPv6 明文 DNS
- **DNSSEC + NOLOG 解析器篩選**（`require_dnssec` / `require_nolog`）
- **自動二進位更新**：來自上游 releases
- **WebUI**：供 KernelSU/APatch 管理器使用（設定、日誌、統計）
- **自訂封鎖清單訂閱**：具備安全的 URL 驗證
- **多語言支援**（English、繁體中文、简体中文）
- **DNS 查詢統計**儀表板
- **封鎖清單／允許清單**圖形化管理
- **DNS 洩漏檢測** — 驗證你的 DNS 流量是否確實經過 dnscrypt-proxy *(v0.7.0)*
- **服務監控 (watchdog) 與 Android 通知** — 服務異常停止時自動重啟並通知 *(v0.7.0)*
- **WebUI 深色／淺色主題切換** *(v0.7.0)*
- **GitHub Actions CI/CD**：自動化模組發版

---

## 系統需求

- Android 7.0 以上（API 24+）
- 下列其一：**Magisk 20.4+**、**KernelSU 0.7.0+** 或 **APatch 10596+**
- 核心需支援 **iptables NAT**（絕大多數裝置皆支援）
- WebUI 管理介面需要 KernelSU 或 APatch（Magisk 沒有 WebUI；在 Magisk 上，action 按鈕改為切換服務開關）

---

## 安裝

1. 從 [Releases](https://github.com/Night114514/dnscrypt-proxy-root/releases) 下載最新的 `dnscrypt-proxy-root-vX.X.X.zip`。
2. 透過 **Magisk Manager**、**KernelSU Manager** 或 **APatch Manager** 刷入。
3. 重新開機。

模組會在安裝過程中自動下載對應你裝置架構的 dnscrypt-proxy 二進位檔。

---

## WebUI

在 **KernelSU** 或 **APatch** 管理器中，點選模組的 WebUI 圖示即可進入設定介面。

| 分頁 | 功能 |
|-----|------|
| **總覽 (Overview)** | 服務狀態、版本資訊、快速啟動／停止／重啟 |
| **設定 (Config)** | 以語法高亮編輯 `dnscrypt-proxy.toml` |
| **封鎖清單 (Blocklist)** | 圖形化網域封鎖／允許清單編輯器 |
| **統計 (Stats)** | DNS 查詢統計（總查詢數、封鎖率、熱門網域、每小時時間軸） |
| **DNS 測試 (DNS Test)** | 比較 dnscrypt-proxy 與直接 DNS 的域名解析與延遲，並可執行 **DNS 洩漏檢測** *(v0.7.0)* |
| **解析器 (Resolvers)** | 圖形化 DNS 伺服器選擇器，附協定／功能標籤 |
| **日誌 (Logs)** | 即時服務與查詢日誌 |
| **更新 (Update)** | 檢查並安裝上游二進位更新 |

WebUI 支援 **English**、**繁體中文** 與 **简体中文**，並依系統語言自動偵測。

右上角提供 **深色／淺色主題切換**（太陽／月亮按鈕）*(v0.7.0)*。選擇會儲存在瀏覽器的 `localStorage`；預設為深色（對 AMOLED 友善）。

---

## 運作原理

### DNS 重導向

- dnscrypt-proxy 監聽於 `127.0.0.1:5354`。
- 在 `OUTPUT` 鏈中的 iptables NAT 鏈（`DNSCRYPT_PROXY`）會將所有對外的明文 DNS 查詢（UDP/TCP port 53）DNAT 到 `127.0.0.1:5354`。
- 啟用 `net.ipv4.conf.all.route_localnet=1`，讓核心不會丟棄從 `OUTPUT` 鏈 DNAT 到 loopback 位址的封包（沒有這一項，重導向會完全失效）。
- 上游解析器 IP（Cloudflare `1.1.1.1`/`1.0.0.1`、Quad9 `9.9.9.9`/`149.112.112.112`）與 `127.0.0.0/8` loopback 範圍會以 `RETURN` 規則排除，避免 bootstrap 與 netprobe 流量被重導回代理而形成解析迴圈。排除是**依目的地 IP** 而非 UID —— 在 Android 上使用 `--uid-owner 0` 是錯誤的，因為 `netd`（系統 DNS 代理）同樣以 root 執行，會導致所有 App 的 DNS 繞過代理。
- 由於 dnscrypt-proxy 僅監聽 IPv4，IPv6 明文 DNS（port 53）會以 `ip6tables` `REJECT` 規則阻擋，避免未加密的 IPv6 DNS 洩漏。

### skip_mount

`skip_mount` 檔案刻意存在，因為本模組**不會**覆蓋任何 system 分割區檔案。所有元件（二進位、設定、webroot）都位於模組目錄內，以獨立 daemon 搭配 iptables 重導向運作。略過 mount 階段可避免不必要的開銷。

### 自動更新（裝置端）

每次開機時，`service.sh` 會在背景觸發更新檢查：

1. 查詢 GitHub API 取得最新 dnscrypt-proxy release
2. 與目前安裝版本比較
3. 若有新版，下載對應架構的 asset
4. 解壓並原子性地替換二進位檔
5. 更新模組中繼資料

檢查頻率限制為每 24 小時一次（可透過 `DNSCRYPT_UPDATE_INTERVAL_SECONDS` 設定）。

### CI/CD 自動更新（GitHub Actions）

排程工作流程每月執行一次（每月 1 號，亦可透過 `workflow_dispatch` 手動觸發）：

1. 檢查上游 dnscrypt-proxy releases
2. 若偵測到新版，更新 `module.prop` 與 `update.json`
3. 建置新的模組 ZIP
4. 建立含更新 asset 的 GitHub Release

這讓 Magisk 內建的模組更新器能通知使用者有新版模組。

### DNS 洩漏檢測 *(v0.7.0)*

DNS 測試頁面新增了 **洩漏檢測** 按鈕。按下後，後端（`dnscrypt-control.sh leak-test`）會：

1. 產生 4 個隨機的 `[a-z0-9-]` 子域名。
2. **透過系統 DNS 路徑**解析每一個（而非直接連向 dnscrypt-proxy），模擬一般 App 受 iptables 重導向的查詢。
3. 稍待片刻後，在 dnscrypt-proxy 的查詢日誌（以及 `nx.log`）中比對每個子域名。
4. 以單行 JSON 回報判定：
   - `protected` — 4 個全部出現在日誌中；DNS 流量確實經過 dnscrypt-proxy。
   - `partial` — 部分出現；可能有部分洩漏。
   - `leaking` — 全部未出現；DNS 流量繞過了 dnscrypt-proxy。

若查詢日誌未啟用，會回傳 `{"status":"error","reason":"query_log_disabled"}`，WebUI 會提示你啟用。檢測全程不連線任何遠端服務——完全在本機執行。

### 服務監控 (Watchdog) 與通知 *(v0.7.0)*

`service.sh` 會啟動一個背景 watchdog，每 60 秒檢查服務一次：

- 若 dnscrypt-proxy **非人為地**停止（即並非使用者主動停止——以 `run/user_stopped` 標記檔追蹤），會發出 Android 通知並**自動重啟服務一次**。重啟成功後會再發出「服務已恢復」通知。
- 通知每次開機上限為 **3 次**，避免 crash loop 灌爆狀態列。
- 上游二進位更新成功後也會發出通知。更新失敗則保持安靜（僅記錄日誌），以免造成噪音。

通知使用 `cmd notification post`（失敗則退回 `su 2000 -c ...`）。

### 深色／淺色主題 *(v0.7.0)*

WebUI 預設採用 AMOLED 深色配色。切換按鈕會將 `document.documentElement.dataset.theme` 切為 `light`，啟用以 CSS 自訂屬性（CSS variables）定義的淺色配色。偏好會保存在 `localStorage`。此功能以注入 `webroot/index.html` 的離線 addon 實作，不修改已打包的 JS/CSS。

---

## 檔案結構

```
dnscrypt-proxy-root/
├── META-INF/                    # Magisk 安裝器中繼資料
├── .github/workflows/           # CI/CD 自動化
│   ├── auto-update.yml          # 排程上游檢查
│   └── release.yml              # 標籤觸發發版
├── config/
│   └── dnscrypt-proxy.toml      # 預設設定
├── scripts/
│   ├── common.sh                # 共用工具函式
│   ├── dnscrypt-control.sh      # 服務控制與 WebUI API
│   └── update-dnscrypt.sh       # 二進位更新器
├── webroot/                     # WebUI 靜態檔案
│   ├── index.html
│   ├── icon.svg
│   ├── addons/                  # 離線 addon：洩漏檢測 + 主題切換 (v0.7.0)
│   └── assets/                  # JS/CSS bundle
├── module.prop                  # 模組中繼資料
├── customize.sh                 # 安裝腳本
├── service.sh                   # 開機服務啟動
├── post-fs-data.sh              # 早期開機掛鉤（不設 iptables；見 service.sh）
├── action.sh                    # Action 按鈕處理
├── uninstall.sh                 # 移除時清理
├── update.json                  # Magisk 更新描述檔
└── skip_mount                   # 略過 system overlay
```

---

## 設定

預設設定位於 `<模組目錄>/config/dnscrypt-proxy.toml`。主要設定：

- **listen_addresses**：`127.0.0.1:5354`
- **server_names**：`cloudflare`、`quad9-dnscrypt-ip4-filter-pri`
- **require_dnssec**：`true`
- **require_nolog**：`true`
- **query_log**：啟用（TSV 格式，供統計頁使用）
- **blocked_names/allowed_names**：檔案式篩選

可透過 WebUI 設定分頁編輯，或以文字編輯器手動修改。

---

## 支援架構

| 架構 | Asset 名稱 |
|---|---|
| arm64-v8a | `android_arm64` |
| armeabi-v7a | `android_arm` |
| x86_64 | `android_x86_64` |
| x86 | `android_i386` |

---

## 疑難排解

- **找不到二進位檔**：在 WebUI 點「強制更新」或使用 action 按鈕
- **DNS 無法運作**：檢查 iptables 規則是否套用（總覽 → 狀態）
- **服務無法啟動**：查看日誌分頁的錯誤訊息
- **WebUI 未顯示**：確認你的管理器支援 WebUI（KernelSU 0.7.0+ / APatch）

---

## 已知限制

- **尚未支援加密的 IPv6 DNS。** dnscrypt-proxy 被設定為僅監聽 IPv4（`127.0.0.1:5354`）；為防止洩漏，IPv6 明文 DNS（port 53）會被*阻擋*而非重導向。僅使用 IPv6 進行 DNS 的 App 會退回 IPv4。
- **需要 iptables NAT 支援。** 少數大幅精簡的自訂 ROM 其核心缺少 NAT/`route_localnet`，透明重導向無法運作。
- DNS 重導向僅涵蓋 port 53（Do53）。硬編自身 DoH/DoT 端點的 App（例如某些瀏覽器）依設計繞過系統解析器，不受影響。

---

## 變更紀錄

### v0.7.0 (2026-07-23)

**新功能**
- **DNS 洩漏檢測**：新增 `leak-test` 命令與 WebUI 按鈕，透過系統 DNS 路徑解析隨機子域名，並檢查查詢日誌以確認流量已加密（protected／partial／leaking 判定）。
- **服務監控 + Android 通知**：`service.sh` 每 60 秒監控 daemon，異常停止時自動重啟一次，並透過 `cmd notification post` 通知（每次開機上限 3 次，並以「使用者停止」標記避免誤報）。二進位更新成功時亦會通知。
- **深色／淺色主題切換**：WebUI 切換按鈕，具 `localStorage` 持久化，預設為 AMOLED 深色配色。

**實作說明**
- WebUI 新增功能以 `webroot/addons/` 下的離線 addon 注入，不動 minified bundle，並相容 KernelSU 與 APatch WebUI 的 `ksu.exec` 慣例。
- 所有 shell 修改維持 `set -u`／busybox／toybox 相容（無 bash-only 語法、無 `bc`）。
- 新增 `README.zh-TW.md` 與 `README.zh-CN.md`，三份 README 皆加入語言切換連結。

### v0.6.0 (2026-06-26)

**安全性修復**
- 修復 WebUI 命令注入漏洞，驗證所有使用者輸入（H3）
- 移除 WebUI 中的第三方分析遠端腳本（H4）
- 新增對下載的 dnscrypt-proxy 二進位檔進行 SHA256 驗證，比對上游簽署的校驗清單
- 移除時主動清除 DNS 查詢日誌以保護隱私

**功能性修復**
- 修復 DNAT 到 `127.0.0.1` 被靜默丟棄的問題——現已啟用 `route_localnet=1`，否則重導向會完全失效（H1）
- 修復讓 App DNS 繞過代理的 iptables 排除邏輯；從 `--uid-owner 0` 改為上游 IP 白名單（H2）
- 移除 `post-fs-data.sh` 中過早的 iptables 設定，該設定會在代理開始監聽前造成早期開機 DNS 黑洞（H5）
- 新增 ip6tables 規則阻擋 IPv6 明文 DNS 洩漏（H6）
- 修復 WebUI 無法載入 JavaScript bundle（空白畫面）的問題，於 `index.html` 引用正確的進入點腳本，並移除孤立／未使用的建置產物
- 強化查詢／協定統計計數，空匹配不再產生格式錯誤的 JSON

**相容性改善**
- 封鎖率計算改用 `awk` 而非 `bc`（Android 上不可用）
- `grep` 樣式改用 `-E` 以相容 toybox
- 行程管理優先使用 PID 檔，不再依賴 `pgrep -x`
- 訂閱 JSON 解析改為逐物件處理以提升穩健性
- 改善 toybox 的 `date +%N` fallback

**其他**
- 設定備份數量限制為最近 5 份
- 修正 README 的自動更新排程說明與 DNS 重導向解釋

---

## 致謝

- [dnscrypt-proxy](https://github.com/dnscrypt/dnscrypt-proxy) by Frank Denis
- [dnscrypt-proxy-android](https://github.com/d3cim/dnscrypt-proxy-android) 提供參考
- [KernelSU](https://kernelsu.org) / [APatch](https://apatch.dev) 提供 WebUI 框架

---

## 授權

本模組依 MIT 授權「按現狀」提供。dnscrypt-proxy 二進位檔依其自身授權（ISC）散布。
