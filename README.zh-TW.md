# DNSCrypt Proxy Root WebUI 模組

[English](README.md) | [繁體中文](README.zh-TW.md) | [简体中文](README.zh-CN.md)

一個 systemless 的 Magisk/KernelSU/APatch 模組，在已 root 的 Android 裝置上執行 **dnscrypt-proxy**，具備：

- **Systemless 加密 DNS**：透過 dnscrypt-proxy（DNSCrypt / DoH）
- **以 Magisk、KernelSU 與 APatch 為封裝目標**；v0.9.1 的管理器／實機矩陣仍為
  [NOT RUN](REAL_DEVICE_ACCEPTANCE.md)，本版本不宣稱已驗證相容性
- **兩種明確整合模式**：預設 `strict` 全系統 Do53 攔截，或以 `upstream_only`
  與 Android Private DNS、VPN 及其他 DNS 前端共存
- **`strict` 模式的 IPv6 DNS 洩漏防護**：只透過模組自有的 ip6tables 鏈阻擋
- **DNSSEC + NOLOG 解析器篩選**（`require_dnssec` / `require_nolog`）
- **自動二進位更新**：來自上游 releases
- **WebUI**：供 KernelSU/APatch 管理器使用（設定、日誌、統計）
- **自訂封鎖清單訂閱**：具備安全的 URL 驗證
- **多語言支援**（English、繁體中文、简体中文）
- **DNS 查詢統計**儀表板
- **封鎖清單／允許清單**圖形化管理
- **DNS 路徑抽樣檢測** — 檢查合成系統 DNS 查詢是否出現在 dnscrypt-proxy 日誌中 *(v0.7.0)*
- **服務監控 (watchdog) 與 Android 通知** — 服務異常停止時自動重啟並通知 *(v0.7.0)*
- **WebUI 深色／淺色主題切換** *(v0.7.0)*
- **GitHub Actions CI/CD**：自動化模組發版

---

## 系統需求

- Android 7.0 以上（API 24+）
- 封裝目標（v0.9.1 尚未完成實機驗收）：**Magisk 20.4+**、**KernelSU 0.7.0+** 或
  **APatch 10596+**
- 更新器需要 `flock`（Android 7+ 的 Toybox 已提供；若系統命令不可用，會改用 root 管理器的 BusyBox）
- 核心需支援 **iptables NAT**（絕大多數裝置皆支援）
- WebUI 管理介面需要 KernelSU 或 APatch（Magisk 沒有 WebUI；在 Magisk 上，action 按鈕改為切換服務開關）

---

## 安裝

1. 從 [Releases](https://github.com/Night114514/dnscrypt-proxy-root/releases) 下載最新的 `dnscrypt-proxy-root-vX.X.X.zip`。
2. 透過 **Magisk Manager**、**KernelSU Manager** 或 **APatch Manager** 刷入。
3. 重新開機。

安裝程式會嘗試下載符合偵測架構的 dnscrypt-proxy 二進位檔；只有 release asset digest 與
二進位檔回報版本都驗證通過才會接受。下載失敗會顯示警告，但不會中止刷入；首次開機會在
啟動 daemon 前重試，也可稍後由 action 按鈕或 KernelSU/APatch WebUI 重試。由於 root 管理器
會把模組暫存在 `/data/adb` 下，安裝階段刻意不執行真實設定／source `-check`；此檢查延後到
首次開機，待 `/data/local/dnscrypt-proxy-root-runtime` 的受保護執行期複本建立後再執行。

> **v0.9.1 升級警告：**若要覆蓋安裝 v0.9.0 或更舊版本，請先匯出或記錄設定、清單與
> 訂閱。v0.9.0 允許 UID 3003 寫入整個 config 目錄；更早版本的配置也不符合 v0.9.1
> 強化後的遷移來源驗證。安裝程式因此會為這些版本一律安裝經稽核的預設值；重開機後
> 請重新套用設定。從 v0.6.0 至 v0.8.0 升級時必須重開機，讓核心安全清除無法區分來源
> 的舊式 IPv6 直接規則。

---

## WebUI

在 **KernelSU** 或 **APatch** 管理器中，點選模組的 WebUI 圖示即可進入設定介面。

| 分頁 | 功能 |
|-----|------|
| **總覽 (Overview)** | 服務狀態、版本資訊、快速啟動／停止／重啟 |
| **設定 (Config)** | 以語法高亮編輯 `dnscrypt-proxy.toml` |
| **封鎖清單 (Blocklist)** | 圖形化網域封鎖／允許清單編輯器 |
| **統計 (Stats)** | DNS 查詢統計（總查詢數、封鎖率、熱門網域、每小時時間軸） |
| **DNS 測試 (DNS Test)** | 比較 dnscrypt-proxy 與直接 DNS 的網域名稱解析與延遲，並可執行 **DNS 洩漏檢測** *(v0.7.0)* |
| **解析器 (Resolvers)** | 圖形化 DNS 伺服器選擇器，附協定／功能標籤 |
| **日誌 (Logs)** | 即時服務與查詢日誌 |
| **更新 (Update)** | 檢查並安裝上游二進位更新 |

WebUI 支援 **English**、**繁體中文** 與 **简体中文**，並依系統語言自動偵測。

右上角提供 **深色／淺色主題切換**（太陽／月亮按鈕）*(v0.7.0)*。選擇會儲存在瀏覽器的 `localStorage`；預設為深色（對 AMOLED 友善）。

---

## 運作原理

### 受保護的執行期複本

`/data/adb/modules/dnscrypt-proxy-root` 下的模組目錄保存經稽核的設定範本、控制腳本、
WebUI，以及安裝下載成功時通過 digest／版本驗證的二進位檔。若該檔不存在，首次開機必須先
下載並驗證後才會啟動 daemon。服務會在 `/data/local/dnscrypt-proxy-root-runtime` 建立另一份
持久化執行樹；這是檔案複本，不是 bind mount 或 mount namespace overlay。模組會從這個可穿越
的執行樹，以數值 UID 3003 直接執行 daemon 與 `-check`，因此不會由 root 行程要求上游程式解析
執行期設定，UID 3003 也不必穿越 root-only 的 `/data/adb` 路徑。生命週期比對仍接受上游 2.1.18
精確的可選 `-child` 形式，但 v0.9.1 的正常啟動一開始就是最終 UID，不需要再次 exec。

執行期根目錄與 `bin` 為 `root:root 0755`。正本 `config` 為 `root:root 0700`，五個受管輸入檔
（以及存在時的 `subscriptions.json`）為 `root:root 0600`。每次啟動前，模組會發佈一份
`3003:root 0500` 的拋棄式 `active` 快照，其五個輸入檔為 `3003:root 0400`；由於行程已是最終
UID，快照會移除 `user_name`。可變的 query／NX log 與 resolver cache 位於 `3003:root 0700`
的 `data`，PID handshake 為 `3003:root 0600`。root 擁有的 `0600` `.layout-owner` 標記必須是
唯一一行以 LF 結尾的 `dnscrypt-proxy-root:5`。若既有目錄沒有標記、父路徑／路徑不安全、是
符號連結，或 ownership／mode 不符，服務會視為衝突並 fail-closed，不接管也不覆寫。解除安裝
也只會在相同路徑、ownership、mode、交易狀態與標記驗證通過後刪除該執行樹。

### DNS 整合模式

整合模式以 root-only 模組狀態保存，與 `dnscrypt-proxy.toml` 分離。狀態檔不存在時預設
為 `strict`；內容無效或為符號連結時會 fail-closed。daemon 健康時切換模式不會重啟：

```sh
sh /data/adb/modules/dnscrypt-proxy-root/scripts/dnscrypt-control.sh get-dns-mode
sh /data/adb/modules/dnscrypt-proxy-root/scripts/dnscrypt-control.sh set-dns-mode strict
sh /data/adb/modules/dnscrypt-proxy-root/scripts/dnscrypt-control.sh set-dns-mode upstream_only
```

預設 **`strict`** 模式：

- dnscrypt-proxy 監聽於 `127.0.0.1:5354`。
- 在 `OUTPUT` 鏈中的 iptables NAT 鏈（`DNSCRYPT_PROXY`）會將所有對外的明文 DNS 查詢（UDP/TCP port 53）DNAT 到 `127.0.0.1:5354`。
- 啟用 `net.ipv4.conf.all.route_localnet=1`，讓核心不會丟棄從 `OUTPUT` 鏈 DNAT 到 loopback 位址的封包（沒有這一項，重導向會完全失效）。
- dnscrypt-proxy 以 Android 的數值 AID_INET 身分（`3003`）執行。只有 effective UID 為 3003 的流量與 `127.0.0.0/8` loopback 範圍使用 `RETURN` 規則，避免 bootstrap／netprobe 流量遞迴回代理。模組不再全域放行任何上游目的地，因此一般 App 無法直接查詢 bootstrap IP 來繞過保護。
- 由於 dnscrypt-proxy 僅監聽 IPv4，IPv6 明文 DNS（port 53）會在模組自有的
  `DNSCRYPT_PROXY6` 鏈中阻擋。隨機世代 token 會把兩條模組鏈綁定到 root-only 的本次開機
  狀態；未證明歸屬的同名鏈，以及 VPN、防火牆或其他模組的同型直接規則都會保留。
- 只有確認精確 daemon、UID 3003、TCP/UDP listener，且有界、與上游無關的 canary 查詢收到
  精確的本機合成 NXDOMAIN 回應後，才會保存並關閉 Android Private DNS；停止服務或離開
  `strict` 時會還原。

**`upstream_only`** 模式只維持 `127.0.0.1:5354` 的 dnscrypt-proxy listener，不安裝全域
iptables/ip6tables 規則、不改 `route_localnet`、也不更動 Android Private DNS。VPN 型過濾器
等本機 DNS 前端可把它當作上游；全系統防漏須由該前端負責，因此模組的 leak-test 會回報
`not_applicable`。

兩種模式冷啟動時，都會先在系統 DNS fail-open 狀態，以 UID 3003 從拋棄式執行期快照執行
真實 `dnscrypt-proxy -check` source/cache 預檢（硬上限 660 秒），再依上游 2.1.18 語義執行最長 3600 秒的 NetProbe，
並保留 30 秒 listener 穩定時間。只有預檢成功，且精確 PID、UID 3003、
`127.0.0.1:5354` 的 TCP LISTEN、UDP bound socket 與本機合成 DNS 回應有界探針
全部通過後才套用政策。
停用、移除或關機時會立即取消尚在執行的預檢與 listener 等待，不會等完整逾時。

執行期設定正本僅允許 root 存取。daemon 只能讀取每次新發佈、由 UID 3003 擁有的唯讀執行快照，
並只可寫入獨立的 UID-3003 `data` 目錄；模組主要服務日誌維持 root-only。staging、備份、驗證、
回滾與提交都會重驗檔案型別、owner、mode 與 device/inode 身分。所有控制與更新入口也會拒絕
不安全的受管輸入；query／NX-log 診斷會先以 UID 3003 複製有大小上限的快照，再交由 root 解析，
而不是在檢查後重新開啟 daemon 可控制的路徑。

### skip_mount

`skip_mount` 檔案刻意存在，因為本模組**不會**覆蓋任何 system 分割區檔案。模組目錄提供
腳本、WebUI、經稽核的範本，以及安裝程式成功驗證的二進位檔（若有）；daemon 則從
`/data/local/dnscrypt-proxy-root-runtime` 的獨立持久化複本執行。本設計不使用 bind mount
或依賴 mount namespace；略過 root 管理器的 system overlay mount 階段，不會阻止建立該
`/data/local` 執行樹。

### 自動更新（裝置端）

每次開機時，`service.sh` 會在背景觸發更新檢查：

1. 查詢 GitHub API 取得最新 dnscrypt-proxy release
2. 與目前安裝版本比較
3. 若有新版，下載對應架構的 asset
4. 解壓、驗證並原子性替換受保護 `/data/local` 執行樹內的二進位檔
5. 更新模組中繼資料

檢查頻率限制為每 24 小時一次（可透過 `DNSCRYPT_UPDATE_INTERVAL_SECONDS` 設定）。
只有檢查成功、已是最新版，或新版完整安裝並通過重啟驗證後，才會記錄限流時間；網路、metadata、下載、驗證、重啟或回滾失敗皆可立即重試。

解壓前，更新器會從 GitHub Release API 取得該精確 asset 的伺服器端 SHA-256，並強制與下載檔比對。雜湊缺失、格式錯誤、無法計算或不相符都會中止安裝。這是 GitHub HTTPS/API 信任邊界內的 fail-closed 完整性檢查，並非獨立的 Minisign 發布者身分驗證。

### CI/CD 自動更新（GitHub Actions）

排程工作流程每月執行一次（每月 1 號，亦可透過 `workflow_dispatch` 手動觸發）：

1. 將上游 dnscrypt-proxy release 與獨立記錄的 `.github/upstream-version` 比較
2. 若偵測到新的上游版本，遞增模組本身獨立的 `vX.X.X` patch 版本
3. 更新 `module.prop`、`update.json` 與上游版本記錄
4. 建置僅含執行階段檔案的模組 ZIP，並以模組版本命名 GitHub Release

這讓 Magisk 內建的模組更新器能通知使用者有新版模組。

### DNS 洩漏檢測 *(v0.7.0)*

DNS 測試頁面新增了 **洩漏檢測** 按鈕。按下後，後端（`dnscrypt-control.sh leak-test`）會：

1. 產生 4 個隨機的 `[a-z0-9-]` 子網域。
2. **透過系統 DNS 路徑**解析每一個（而非直接連向 dnscrypt-proxy），模擬一般 App 受 iptables 重導向的查詢。
3. 稍待片刻後，在 dnscrypt-proxy 的查詢日誌（以及 `nx.log`）中比對每個子網域。
4. 以單行 JSON 回報抽樣日誌可見性（為了 API 相容而保留舊狀態名稱）：
   - `protected` — 4 個測試查詢全都出現在 dnscrypt-proxy 日誌中。
   - `partial` — 只有部分測試查詢出現；請檢查可能的繞過或查詢／日誌失敗。
   - `leaking` — 測試查詢全都未出現；請檢查可能的繞過或查詢／日誌失敗。

若查詢日誌未啟用，會回傳 `{"status":"error","reason":"query_log_disabled"}`，WebUI 會提示你啟用。檢測不會連線專用的第三方洩漏測試網站，但合成 DNS 查詢仍會經過已設定的 DNS／上游路徑，並可能出現在網路或上游 resolver 日誌中。此抽樣不涵蓋 App 自有 DoH／DoT、所有 DNS 路徑，也不能證明全系統沒有洩漏。

### 服務監控 (Watchdog) 與通知 *(v0.7.0)*

`service.sh` 會啟動一個背景 watchdog，每 60 秒檢查服務一次：

- 若精確程序、UID、本機 TCP/UDP listener、本機 handler 有界探針或所選整合政策非人為地異常，會發出 Android
  通知，並以預設 60、120、240、480、900 秒的上限倍增退避重試。健康恢復、人為停止、
  正在啟動或並行人工控制會重設延遲。飛航模式、Wi-Fi 中斷與上游 resolver 離線只會
  標示為 `degraded`，不會重啟仍健康的本機 daemon。
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
├── .github/
│   ├── upstream-version         # 獨立記錄的 dnscrypt-proxy 版本
│   └── workflows/               # CI/CD 自動化
│       ├── auto-update.yml      # 排程上游檢查
│       ├── release.yml          # 經驗證的模組版本發版
│       └── test.yml             # dash/BusyBox ash 測試與 ShellCheck
├── config/
│   └── dnscrypt-proxy.toml      # 隨模組封裝的預設範本
├── scripts/
│   ├── common.sh                # 共用工具函式
│   ├── dnscrypt-control.sh      # 服務控制與 WebUI API
│   ├── update-dnscrypt.sh       # 二進位更新器
│   └── watchdog.sh              # 單一實例健康檢查與自動恢復
├── tests/                        # POSIX sh 更新器回歸測試與 mock
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

隨模組封裝的預設範本位於 `<模組目錄>/config/dnscrypt-proxy.toml`。首次開機後，可編輯的
root-only 權威設定為 `/data/local/dnscrypt-proxy-root-runtime/config/dnscrypt-proxy.toml`；
daemon 會讀取由它產生的唯讀執行快照。請透過 WebUI 修改權威設定，或以 root 直接編輯
該持久化路徑；模組範本只用於初次建立執行樹。主要設定：

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

- **尚未支援加密的 IPv6 DNS。** dnscrypt-proxy 被設定為僅監聽 IPv4（`127.0.0.1:5354`）；為防止洩漏，IPv6 明文 DNS（port 53）會被*阻擋*而非重導向。在 `strict` 模式下，用戶端必須支援並實際使用 IPv4 DNS fallback；否則僅支援 IPv6 的 DNS 用戶端查詢會失敗。
- **需要 iptables NAT 支援。** 少數大幅精簡的自訂 ROM 其核心缺少 NAT/`route_localnet`，透明重導向無法運作。
- DNS 重導向僅涵蓋 port 53（Do53）。硬編自身 DoH/DoT 端點的 App（例如某些瀏覽器）依設計繞過系統解析器，不受影響。
- `strict` 只擁有模組的 OUTPUT jump 與專用鏈；不宣稱涵蓋 PREROUTING／分享網路用戶端，
  也沒有特定 VPN／fake-IP／TUN 的推測性豁免。
- `upstream_only` 刻意不提供全系統攔截或通用 DNS 洩漏判定。
- 持久化 `/data/local` 執行期複本的 SELinux 執行／存取行為，以及 Magisk、KernelSU、
  APatch 的生命週期相容性（包括 Xiaomi 14T Pro／Android 16 參考環境）皆為 **NOT RUN
  （未執行）**；本版本不宣稱相容這些組合。
- Xiaomi 14T Pro／Android 16 與特定 VPN 產品的互通性仍屬人工驗收項目；CI 驗證的是可攜式
  shell 行為，不能宣稱涵蓋這些真機組合。請依[實機驗收表](REAL_DEVICE_ACCEPTANCE.md)
  留存 argv／UID／socket／規則計數器與實際 DNS 出口證據；v0.9.1 各列目前明確標為
  **NOT RUN（未執行）**。

---

## 變更紀錄

### v0.9.1 (2026-09-07)

- 支援 dnscrypt-proxy 2.1.18 精確的可選 `-child` exec 形式，分別驗證 UID 3003、實際
  TCP/UDP socket、本機合成 NXDOMAIN 回應與上游可達性。
- daemon 與 `-check` 皆以 UID 3003 從經標記及權限驗證的持久化
  `/data/local/dnscrypt-proxy-root-runtime` 拋棄式快照執行；root-only 正本、UID-3003 唯讀
  執行快照及可變 data 分離。不安全或無標記的衝突會 fail-closed，解除安裝只刪除驗證過的自有樹。
- 新增交易式切換的 `strict`／`upstream_only`、有界 source/cache 預檢、符合上游語義的
  NetProbe 寬限、degraded/offline 狀態與有上限的 watchdog 倍增退避。
- 以 token 綁定的本次開機 ownership／adoption marker 與完整規則順序驗證保留未證明歸屬的同名鏈
  或直接第三方規則，且只在 listener 就緒後套用 strict 導流。
- quick-mode 改為保守 TOML lexer、受保護 staging/inode 驗證、原子替換及重啟失敗回滾；
  root-only 設定正本與 UID-3003 唯讀快照會隔離控制平面及 daemon 可寫資料。
- 擴充 dash／BusyBox ash 的生命週期、更新器、socket、模式、防火牆與 TOML 測試。
- 升級時重設不符合新版遷移來源驗證邊界的 v0.9.0（含）以前設定；請先匯出、重開機，
  再重新套用。

### v0.9.0 (2026-08-29)

- 修復 v0.8 稽核確認的備份清理、訂閱累積、IPv6 規則、測速、watchdog、base64、空清單還原、下載 fallback、資源／日誌路徑與 resolver 空白問題。
- 強化精確 PID、DNS／防火牆 readiness、Android Private DNS 還原、模組升級設定遷移、停用／移除清理與 AID_INET 專用執行身分。
- 上游壓縮檔驗證改為強制 fail-closed，並加入二進位／設定驗證、交易式重啟與明確回滾狀態。
- WebUI 現在會顯示 shell 失敗，清單採原子寫入；查詢統計依官方 TSV return code 計算，不再把錯誤當成功或顯示假資料。
- 依目前 KernelSU／APatch 實作重新驗證中繼資料、ZIP 結構、生命週期、權限、WebUI bridge 與 Markdown 更新描述檔，並擴充 dash／BusyBox ash／JavaScript CI。

完整內容請參閱 [CHANGELOG.md](CHANGELOG.md)。

### v0.8.0 (2026-08-18)

- 將模組 `vX.X.X` Release 與獨立追蹤的上游 dnscrypt-proxy 版本分離。
- 修正更新限流：網路失敗或 metadata 格式錯誤後可立即重試。
- 使用核心 `flock` 實作異常終止後可安全恢復的更新鎖，並涵蓋 BusyBox fallback 與舊鎖遷移。
- 明確說明可選 checksum 比對不屬於 Minisign 身分驗證，且仍為 best-effort。
- 新增 dash 與 BusyBox ash 下的 POSIX `sh` 更新器測試，並加入 ShellCheck 與 GitHub Actions CI。
- 統一繁體中文 README 與 WebUI 的網域用語。
- 舊安裝包仍固定使用不可變的 `v0.7.0` 更新描述檔，需手動安裝一次 `v0.8.0`；本版已為後續更新切換至穩定描述檔網址。

### v0.7.0 (2026-07-23)

**新功能**
- **DNS 路徑抽樣檢測**：新增 `leak-test` 命令與 WebUI 按鈕，透過系統 DNS 路徑解析隨機子網域，並回報哪些樣本出現在查詢日誌；為相容而保留的 protected／partial／leaking 名稱不能證明所有 DNS 路徑都已加密。
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
- 新增 best-effort SHA256 比對，使用同一 release 的檢查碼清單檢查下載的 dnscrypt-proxy 壓縮檔；該清單未經簽章驗證，檢查碼不可用時不會阻止安裝
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
