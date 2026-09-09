# DNSCrypt Proxy Root

在已 Root 的 Android 裝置上執行 dnscrypt-proxy，提供加密 DNS、受管理的域名／IP 清單及本機 DNS 上游。

[下載 Release](https://github.com/Night114514/dnscrypt-proxy-root/releases) ·
[English](README.md) · [简体中文](README.zh-CN.md) · [更新紀錄](CHANGELOG.md)

> **v0.9.2 狀態：**模組追蹤 dnscrypt-proxy 2.1.18。dash、BusyBox ash、JavaScript、lint、
> 回滾及封裝自動測試不能取代 Android 實機測試；v0.9.2 的
> [實機驗收矩陣](REAL_DEVICE_ACCEPTANCE.md) 仍明確標為 **NOT RUN**。請勿假定所有裝置、
> Root 管理器、VPN 或 DNS 前端均已驗證相容。

## 選擇整合模式

| | `strict`（預設） | `upstream_only` |
|---|---|---|
| 適用情境 | 由本模組接管一般系統 Do53 | 由另一個 DNS 前端或代理負責接管與分流 |
| 本機服務 | `127.0.0.1:5354` | `127.0.0.1:5354` |
| IPv4 Do53 | 重導向至本機服務；保留 daemon UID／loopback 豁免 | 不建立本模組的全域重導向 |
| IPv6 Do53 | 透過本模組自有鏈封鎖；保留 daemon UID 豁免 | 不建立本模組的封鎖政策 |
| Android 私人 DNS | strict 政策運作時保存並關閉；停止或離開模式時還原 | 保留／還原原有設定 |
| 與其他 DNS 接管者並用 | 須核對規則次序及回路 | 須在前端明確指定本模組作上游 |

`upstream_only` 不會自動令所有 App 使用本模組。前端必須能在其網絡 namespace 連接
`127.0.0.1:5354`，並自行完成 DNS 接管／分流。

整合模式與 WebUI 的解析器 preset 是兩回事：`strict`／`upstream_only` 控制 Android 路由政策，
`quick-mode` 則選擇解析器及協定偏好。

## 系統需求

- 項目目標為 Android 7.0+；實際支援視乎裝置及 Root 管理器驗收。
- Magisk、KernelSU 或 APatch 模組環境。
- `strict` 需要可用的 iptables／ip6tables、NAT、owner／comment 等核心能力。
- 需要 root shell 的鎖定及診斷命令；部分命令可由 Root 管理器 BusyBox 作後備。
- 安裝／核心更新及首次取得解析器來源時可能需要連接 GitHub。

WebUI 供 KernelSU／APatch 使用；Magisk 使用者可經 action 按鈕及 root shell 控制。

| 裝置 ABI | 上游 Release asset |
|---|---|
| arm64-v8a | `android_arm64` |
| armeabi-v7a | `android_arm` |
| x86_64 | `android_x86_64` |
| x86 | `android_i386` |

## 安裝與升級

1. 從 [Releases](https://github.com/Night114514/dnscrypt-proxy-root/releases) 下載 `dnscrypt-proxy-root-v0.9.2.zip`。
2. 在 Root 管理器安裝模組。
3. 重新開機。
4. 檢查完整服務狀態，再選擇符合 DNS 架構的整合模式。

模組 ZIP 不包含 dnscrypt-proxy 執行檔。安裝時會嘗試下載正確的官方 asset，並核對 Release digest
及執行檔回報版本。下載失敗會警告但不會放棄模組安裝；首次開機或稍後手動更新可再重試。

> **由 v0.9.0 或更舊版本升級：**請先匯出或記錄設定、清單與訂閱。舊版 layout 不符合強化後的
> 遷移來源邊界，安裝器會改用已稽核預設值；重開機後再套用所需輸入。由 v0.6.0–v0.8.0 直接升級
> 必須重開機，以安全清除無法辨認來源的舊式 per-boot IPv6 規則。可信的 v0.9.1 canonical
> generation 會由 v0.9.2 安裝器保留。

## 首次驗證與常用操作

以下在 **Android root shell** 執行；使用 ADB 時先進入 `adb shell`，再執行 `su`。

```sh
DPR_CTL=/data/adb/modules/dnscrypt-proxy-root/scripts/dnscrypt-control.sh

sh "$DPR_CTL" status
sh "$DPR_CTL" get-dns-mode
sh "$DPR_CTL" logs
```

程序存在不等於 DNS 防護正常。請同時檢查 `healthy`、`service_state`、`listener`、`local_dns`、
`firewall`、`upstream`、`config_apply_state` 及 `start_failure`。

| 狀態例子 | 意義 |
|---|---|
| `healthy` | 本機 DNS 及所選政策通過檢查；上游探測仍可能是 unknown |
| `degraded` | 本機服務／政策正常，但最近上游探測失敗 |
| `starting` | 仍在有時限的啟動／預檢期間 |
| `policy_fault` | 程序可能存在，但所選系統政策未通過驗證 |
| `stopped`／`start_*` | 服務已停止，或在指定啟動階段失敗 |

常用操作：

```sh
sh "$DPR_CTL" start
sh "$DPR_CTL" stop
sh "$DPR_CTL" restart

sh "$DPR_CTL" set-dns-mode upstream_only
sh "$DPR_CTL" set-dns-mode strict
```

以上是可選操作，毋須依次全部執行。健康 daemon 運作時切換模式只改所選 Android 政策，毋須重新
建立程序；daemon 停止時切換只保存選擇，不會自行啟動服務。

## WebUI 與 canonical generation

在 KernelSU／APatch 模組頁開啟 WebUI，可查看後端真實狀態、編輯 TOML／受管理清單、選擇解析器、
管理訂閱、查看統計及日誌、執行有界診斷、更新核心，以及匯出／匯入 generation。TOML 控制項是
純文字編輯器。

v0.9.2 WebUI 由無依賴的 `webui/src/` 源碼建置；提交到 `webroot/` 的五個檔案可確定性重建，
不再包含 development React bundle 或遠端分析。橋接只允許列明的控制操作；路徑、擁有權、鎖、
驗證及回滾仍由 root 後端強制執行。

| 路徑 | 用途 |
|---|---|
| `/data/adb/modules/dnscrypt-proxy-root/config/` | 隨模組提供的已稽核範本；不是即時單一真實來源 |
| `/data/local/dnscrypt-proxy-root-runtime/config/` | Canonical TOML、四份清單及訂閱 |
| `/data/local/dnscrypt-proxy-root-runtime/active/` | 目前 daemon generation 使用的唯讀 snapshot |
| `/data/local/dnscrypt-proxy-root-runtime/data/` | 解析器 cache 及已設定的 query／NX logs |

不要直接編輯 `active/`；請使用 WebUI／後端，或以 root 小心編輯 canonical 路徑。

儲存與套用刻意分開：

- **設定檔－儲存（待套用）：**驗證後以 atomic replace 更新 canonical TOML；成功訊息不會改變運行中 snapshot。
- **設定檔－儲存並重啟：**先儲存，再要求重啟；若重啟失敗，已儲存 TOML 仍是 canonical，介面會明確報錯。
- **受管理清單－儲存（待套用）：**更新一份 canonical 清單而不重啟。
- **受管理清單－儲存並套用：**服務運作且沒有 canonical 輸入已處於待套用狀態時，才會以新
  generation 重啟；若啟動失敗，後端還原上一份 canonical 清單，再啟動已知可工作的 generation。
  若已有待套用或不可用的 generation，後端會在改動所選清單前拒絕操作；請先重啟或還原該代設定。
  若連 rollback replace 也失敗，後端會保留已驗證的舊清單備份，並回報其完整路徑供手動復原。
- `status.config_apply_state` 為 `pending`、`applied` 或 `unavailable`；不要從「儲存成功」推斷已套用。

清單讀取及寫入使用同一 canonical 後端 API。WebUI 不會再讀模組範本、卻寫入另一個 runtime 路徑。

## 備份與還原

`export-config` 輸出一份嚴格的 generation manifest（schema v2），包括 TOML、四份受管理清單及訂閱。
Android 整合模式刻意獨立，匯入不會改動它。

匯入只接受精確的 v1／v2 欄位 layout，逐欄限制大小，在私人 staging 目錄解碼及保護所有內容，
並讓 dnscrypt-proxy 連同 staged lists 驗證整份 generation。通過後才開始 canonical commit。完整舊
generation 及 recovery marker 會保留；任何 commit 失敗或中斷均還原所有 canonical 輸入。
待處理的復原會在下一個 control action（包括 `status`）dispatch 前完成。成功匯入後仍須重啟才會套用。

訂閱採用嚴格 JSON 陣列。每個項目必須剛好包含一個 HTTPS `url` 字串及一個 `enabled` 布林值
（兩個欄位次序不限）；未知／重複欄位、經跳脫或不安全的 URL，以及錯誤型別的布林值都會被拒絕。
一般多行 JSON 空白可以使用。

升級或大幅修改前請先備份；不要把 PID、鎖、active snapshot 或日誌等 transient 檔放入設定備份。

## 更新 dnscrypt-proxy

```sh
sh "$DPR_CTL" check-update
sh "$DPR_CTL" update
```

- **模組更新**由 Root 管理器安裝 Release ZIP，並可能要求重開機。
- **核心更新**使用 WebUI 或 `update`；`check-update` 只比較版本。
- 開機會觸發背景核心檢查，成功檢查受預設 24 小時間隔限制；並非每 24 小時喚醒的常駐排程。
- 更新器驗證 Release asset digest、執行檔版本、staged configuration 及 rollback 路徑。GitHub Release
  checksum 只證明與該發布渠道一致，不是獨立發布者簽章。
- 中斷時只清理該程序精確擁有的 `tmp/update-<pid>` workspace。

## 診斷、私隱與路由限制

- `strict` 主要控制一般 Do53，不能保證攔截 App 自有 DoH／DoT、所有 VPN DNS 路徑或其他 namespace。
- strict 封鎖 IPv6 Do53，而不是重導向到 IPv6 listener；這與回答 AAAA 或使用 IPv6 上游不同。
  IPv6-only 網絡仍需實機驗收。
- 啟動／恢復先移除舊政策，待本機 DNS 預檢成功才加上 strict 規則；該期間刻意 fail-open。
- 預設範本開啟 query log，供統計及抽樣路徑檢查。分享前請檢查域名資料。解析器 `require_nolog`
  是伺服器篩選條件，不代表本機沒有 query log。
- `leak-test` 只檢查四個生成樣本有否出現在 query／NX logs；相容用的
  `protected`／`partial`／`leaking` 名稱不能證明所有 DNS 路徑狀態，在 `upstream_only` 亦不適用於
  判斷全系統接管。
- `strict` 下 `dns-test` 的指定目的 DNS 查詢會受現行重導向政策影響。結果標為
  `comparison_scope=policy_affected`，不是直接 DNS bypass 量測。

## 常見問題

| 情況 | 先檢查甚麼 |
|---|---|
| 安裝後沒有啟動 | `status.start_failure`、下載網絡及 `logs` |
| 與 VPN／另一 DNS 模組並用後異常 | 誰接管 Do53、是否應用 `upstream_only`、上游地址及回路 |
| 加入允許清單仍被封鎖 | Canonical 清單、`config_apply_state`、其他前端／上游是否另有過濾 |
| 有程序但政策不正常 | `service_state`／`firewall`，不要只看 `running` |
| 停用／移除 | 先執行 `stop` 並核對結果，再於管理器停用／移除及按要求重開機 |

watchdog 會檢查本機服務與所選政策；人為停止不視為故障，上游暫時離線亦不會造成無限重啟。

回報問題時請附模組／Root 管理器／Android 版本、整合模式、相關錯誤及已刪除私人資料的日誌。
切勿公開訂閱 token 或未審閱的查詢記錄。

## 開發與驗證

常用 repository 檢查：

```sh
node webui/build.mjs --check
node tests/test-webui-bridge.js
dash tests/test-update-dnscrypt.sh
dash tests/test-dnscrypt-control.sh
busybox ash tests/test-update-dnscrypt.sh
busybox ash tests/test-dnscrypt-control.sh
```

`node webui/build.mjs` 會按 build script 聲明，刻意以確定性檔案取代 `webroot/`。CI 亦檢查 shell／
JavaScript 語法、ShellCheck、兩套 shell 矩陣、release metadata、ZIP 權限／排除規則及授權檔案。
這些都不是 Android 安裝、SELinux、firewall、VPN 或實際封包路徑的證據；實機結果須記錄於
[REAL_DEVICE_ACCEPTANCE.md](REAL_DEVICE_ACCEPTANCE.md)。

自動發布只 checkout 通過 reusable tests 的精確事件 SHA；若 `master` 已前進就中止，避免以較新的
未測 branch tip 打 tag／ZIP。

## 授權與第三方內容

項目自有程式碼採 [MIT License](LICENSE)。第三方內容保留各自條款，詳見
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) 及 [LICENSES/](LICENSES/)。

模組 ZIP 包含一份原樣 Magisk installer script，依 GPL-3.0-only 提供，並列出固定 source commit／
blob provenance。dnscrypt-proxy 執行檔不預載於 ZIP，但更新器會在裝置安裝官方 ISC 授權的 2.1.18
asset，因此 ZIP 亦包含相應 ISC notice。
