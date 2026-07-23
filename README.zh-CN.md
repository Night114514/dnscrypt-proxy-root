# DNSCrypt Proxy Root WebUI 模块

[English](README.md) | [繁體中文](README.zh-TW.md) | [简体中文](README.zh-CN.md)

一个 systemless 的 Magisk/KernelSU/APatch 模块，在已 root 的 Android 设备上运行 **dnscrypt-proxy**，具备：

- **Systemless 加密 DNS**：通过 dnscrypt-proxy（DNSCrypt / DoH）
- **兼容 Magisk、KernelSU 与 APatch**
- **自动 DNS 重定向**：通过 iptables DNAT 覆盖所有 App（透明代理，无需逐个设置）
- **IPv6 DNS 泄漏防护**：以 ip6tables 阻挡 IPv6 明文 DNS
- **DNSSEC + NOLOG 解析器筛选**（`require_dnssec` / `require_nolog`）
- **自动二进制更新**：来自上游 releases
- **WebUI**：供 KernelSU/APatch 管理器使用（配置、日志、统计）
- **自定义屏蔽列表订阅**：具备安全的 URL 验证
- **多语言支持**（English、繁體中文、简体中文）
- **DNS 查询统计**仪表盘
- **屏蔽列表／允许列表**图形化管理
- **DNS 泄漏检测** — 验证你的 DNS 流量是否确实经过 dnscrypt-proxy *(v0.7.0)*
- **服务监控 (watchdog) 与 Android 通知** — 服务异常停止时自动重启并通知 *(v0.7.0)*
- **WebUI 深色／浅色主题切换** *(v0.7.0)*
- **GitHub Actions CI/CD**：自动化模块发版

---

## 系统需求

- Android 7.0 以上（API 24+）
- 下列其一：**Magisk 20.4+**、**KernelSU 0.7.0+** 或 **APatch 10596+**
- 内核需支持 **iptables NAT**（绝大多数设备均支持）
- WebUI 管理界面需要 KernelSU 或 APatch（Magisk 没有 WebUI；在 Magisk 上，action 按钮改为切换服务开关）

---

## 安装

1. 从 [Releases](https://github.com/Night114514/dnscrypt-proxy-root/releases) 下载最新的 `dnscrypt-proxy-root-vX.X.X.zip`。
2. 通过 **Magisk Manager**、**KernelSU Manager** 或 **APatch Manager** 刷入。
3. 重启。

模块会在安装过程中自动下载对应你设备架构的 dnscrypt-proxy 二进制文件。

---

## WebUI

在 **KernelSU** 或 **APatch** 管理器中，点击模块的 WebUI 图标即可进入配置界面。

| 标签页 | 功能 |
|-----|------|
| **概览 (Overview)** | 服务状态、版本信息、快速启动／停止／重启 |
| **配置 (Config)** | 以语法高亮编辑 `dnscrypt-proxy.toml` |
| **屏蔽列表 (Blocklist)** | 图形化域名屏蔽／允许列表编辑器 |
| **统计 (Stats)** | DNS 查询统计（总查询数、屏蔽率、热门域名、每小时时间轴） |
| **DNS 测试 (DNS Test)** | 比较 dnscrypt-proxy 与直接 DNS 的域名解析与延迟，并可执行 **DNS 泄漏检测** *(v0.7.0)* |
| **解析器 (Resolvers)** | 图形化 DNS 服务器选择器，附协议／功能标签 |
| **日志 (Logs)** | 实时服务与查询日志 |
| **更新 (Update)** | 检查并安装上游二进制更新 |

WebUI 支持 **English**、**繁體中文** 与 **简体中文**，并依系统语言自动检测。

右上角提供 **深色／浅色主题切换**（太阳／月亮按钮）*(v0.7.0)*。选择会保存在浏览器的 `localStorage`；默认为深色（对 AMOLED 友好）。

---

## 工作原理

### DNS 重定向

- dnscrypt-proxy 监听于 `127.0.0.1:5354`。
- 在 `OUTPUT` 链中的 iptables NAT 链（`DNSCRYPT_PROXY`）会将所有对外的明文 DNS 查询（UDP/TCP port 53）DNAT 到 `127.0.0.1:5354`。
- 启用 `net.ipv4.conf.all.route_localnet=1`，让内核不会丢弃从 `OUTPUT` 链 DNAT 到 loopback 地址的数据包（没有这一项，重定向会完全失效）。
- 上游解析器 IP（Cloudflare `1.1.1.1`/`1.0.0.1`、Quad9 `9.9.9.9`/`149.112.112.112`）与 `127.0.0.0/8` loopback 范围会以 `RETURN` 规则排除，避免 bootstrap 与 netprobe 流量被重定向回代理而形成解析环路。排除是**依目标 IP** 而非 UID —— 在 Android 上使用 `--uid-owner 0` 是错误的，因为 `netd`（系统 DNS 代理）同样以 root 运行，会导致所有 App 的 DNS 绕过代理。
- 由于 dnscrypt-proxy 仅监听 IPv4，IPv6 明文 DNS（port 53）会以 `ip6tables` `REJECT` 规则阻挡，避免未加密的 IPv6 DNS 泄漏。

### skip_mount

`skip_mount` 文件刻意存在，因为本模块**不会**覆盖任何 system 分区文件。所有组件（二进制、配置、webroot）都位于模块目录内，以独立 daemon 搭配 iptables 重定向运行。跳过 mount 阶段可避免不必要的开销。

### 自动更新（设备端）

每次开机时，`service.sh` 会在后台触发更新检查：

1. 查询 GitHub API 获取最新 dnscrypt-proxy release
2. 与当前安装版本比较
3. 若有新版，下载对应架构的 asset
4. 解压并原子性地替换二进制文件
5. 更新模块元数据

检查频率限制为每 24 小时一次（可通过 `DNSCRYPT_UPDATE_INTERVAL_SECONDS` 配置）。

### CI/CD 自动更新（GitHub Actions）

计划任务工作流每月运行一次（每月 1 号，也可通过 `workflow_dispatch` 手动触发）：

1. 检查上游 dnscrypt-proxy releases
2. 若检测到新版，更新 `module.prop` 与 `update.json`
3. 构建新的模块 ZIP
4. 创建含更新 asset 的 GitHub Release

这让 Magisk 内置的模块更新器能通知用户有新版模块。

### DNS 泄漏检测 *(v0.7.0)*

DNS 测试页面新增了 **泄漏检测** 按钮。按下后，后端（`dnscrypt-control.sh leak-test`）会：

1. 生成 4 个随机的 `[a-z0-9-]` 子域名。
2. **通过系统 DNS 路径**解析每一个（而非直接连向 dnscrypt-proxy），模拟一般 App 受 iptables 重定向的查询。
3. 稍等片刻后，在 dnscrypt-proxy 的查询日志（以及 `nx.log`）中比对每个子域名。
4. 以单行 JSON 回报判定：
   - `protected` — 4 个全部出现在日志中；DNS 流量确实经过 dnscrypt-proxy。
   - `partial` — 部分出现；可能有部分泄漏。
   - `leaking` — 全部未出现；DNS 流量绕过了 dnscrypt-proxy。

若查询日志未启用，会返回 `{"status":"error","reason":"query_log_disabled"}`，WebUI 会提示你启用。检测全程不连接任何远端服务——完全在本机运行。

### 服务监控 (Watchdog) 与通知 *(v0.7.0)*

`service.sh` 会启动一个后台 watchdog，每 60 秒检查服务一次：

- 若 dnscrypt-proxy **非人为地**停止（即并非用户主动停止——以 `run/user_stopped` 标记文件追踪），会发出 Android 通知并**自动重启服务一次**。重启成功后会再发出「服务已恢复」通知。
- 通知每次开机上限为 **3 次**，避免 crash loop 灌爆状态栏。
- 上游二进制更新成功后也会发出通知。更新失败则保持安静（仅记录日志），以免造成噪音。

通知使用 `cmd notification post`（失败则退回 `su 2000 -c ...`）。

### 深色／浅色主题 *(v0.7.0)*

WebUI 默认采用 AMOLED 深色配色。切换按钮会将 `document.documentElement.dataset.theme` 切为 `light`，启用以 CSS 自定义属性（CSS variables）定义的浅色配色。偏好会保存在 `localStorage`。此功能以注入 `webroot/index.html` 的离线 addon 实现，不修改已打包的 JS/CSS。

---

## 文件结构

```
dnscrypt-proxy-root/
├── META-INF/                    # Magisk 安装器元数据
├── .github/workflows/           # CI/CD 自动化
│   ├── auto-update.yml          # 计划上游检查
│   └── release.yml              # 标签触发发版
├── config/
│   └── dnscrypt-proxy.toml      # 默认配置
├── scripts/
│   ├── common.sh                # 共用工具函数
│   ├── dnscrypt-control.sh      # 服务控制与 WebUI API
│   └── update-dnscrypt.sh       # 二进制更新器
├── webroot/                     # WebUI 静态文件
│   ├── index.html
│   ├── icon.svg
│   ├── addons/                  # 离线 addon：泄漏检测 + 主题切换 (v0.7.0)
│   └── assets/                  # JS/CSS bundle
├── module.prop                  # 模块元数据
├── customize.sh                 # 安装脚本
├── service.sh                   # 开机服务启动
├── post-fs-data.sh              # 早期开机钩子（不设 iptables；见 service.sh）
├── action.sh                    # Action 按钮处理
├── uninstall.sh                 # 移除时清理
├── update.json                  # Magisk 更新描述文件
└── skip_mount                   # 跳过 system overlay
```

---

## 配置

默认配置位于 `<模块目录>/config/dnscrypt-proxy.toml`。主要设置：

- **listen_addresses**：`127.0.0.1:5354`
- **server_names**：`cloudflare`、`quad9-dnscrypt-ip4-filter-pri`
- **require_dnssec**：`true`
- **require_nolog**：`true`
- **query_log**：启用（TSV 格式，供统计页使用）
- **blocked_names/allowed_names**：基于文件的筛选

可通过 WebUI 配置标签页编辑，或以文本编辑器手动修改。

---

## 支持架构

| 架构 | Asset 名称 |
|---|---|
| arm64-v8a | `android_arm64` |
| armeabi-v7a | `android_arm` |
| x86_64 | `android_x86_64` |
| x86 | `android_i386` |

---

## 故障排查

- **找不到二进制文件**：在 WebUI 点「强制更新」或使用 action 按钮
- **DNS 无法工作**：检查 iptables 规则是否应用（概览 → 状态）
- **服务无法启动**：查看日志标签页的错误信息
- **WebUI 未显示**：确认你的管理器支持 WebUI（KernelSU 0.7.0+ / APatch）

---

## 已知限制

- **尚未支持加密的 IPv6 DNS。** dnscrypt-proxy 被配置为仅监听 IPv4（`127.0.0.1:5354`）；为防止泄漏，IPv6 明文 DNS（port 53）会被*阻挡*而非重定向。仅使用 IPv6 进行 DNS 的 App 会回退到 IPv4。
- **需要 iptables NAT 支持。** 少数大幅精简的自定义 ROM 其内核缺少 NAT/`route_localnet`，透明重定向无法工作。
- DNS 重定向仅涵盖 port 53（Do53）。硬编码自身 DoH/DoT 端点的 App（例如某些浏览器）依设计绕过系统解析器，不受影响。

---

## 变更日志

### v0.7.0 (2026-07-23)

**新功能**
- **DNS 泄漏检测**：新增 `leak-test` 命令与 WebUI 按钮，通过系统 DNS 路径解析随机子域名，并检查查询日志以确认流量已加密（protected／partial／leaking 判定）。
- **服务监控 + Android 通知**：`service.sh` 每 60 秒监控 daemon，异常停止时自动重启一次，并通过 `cmd notification post` 通知（每次开机上限 3 次，并以「用户停止」标记避免误报）。二进制更新成功时也会通知。
- **深色／浅色主题切换**：WebUI 切换按钮，具 `localStorage` 持久化，默认为 AMOLED 深色配色。

**实现说明**
- WebUI 新增功能以 `webroot/addons/` 下的离线 addon 注入，不动 minified bundle，并兼容 KernelSU 与 APatch WebUI 的 `ksu.exec` 约定。
- 所有 shell 修改保持 `set -u`／busybox／toybox 兼容（无 bash-only 语法、无 `bc`）。
- 新增 `README.zh-TW.md` 与 `README.zh-CN.md`，三份 README 均加入语言切换链接。

### v0.6.0 (2026-06-26)

**安全性修复**
- 修复 WebUI 命令注入漏洞，验证所有用户输入（H3）
- 移除 WebUI 中的第三方分析远端脚本（H4）
- 新增对下载的 dnscrypt-proxy 二进制文件进行 SHA256 验证，比对上游签名的校验列表
- 移除时主动清除 DNS 查询日志以保护隐私

**功能性修复**
- 修复 DNAT 到 `127.0.0.1` 被静默丢弃的问题——现已启用 `route_localnet=1`，否则重定向会完全失效（H1）
- 修复让 App DNS 绕过代理的 iptables 排除逻辑；从 `--uid-owner 0` 改为上游 IP 白名单（H2）
- 移除 `post-fs-data.sh` 中过早的 iptables 设置，该设置会在代理开始监听前造成早期开机 DNS 黑洞（H5）
- 新增 ip6tables 规则阻挡 IPv6 明文 DNS 泄漏（H6）
- 修复 WebUI 无法加载 JavaScript bundle（空白画面）的问题，于 `index.html` 引用正确的入口脚本，并移除孤立／未使用的构建产物
- 强化查询／协议统计计数，空匹配不再产生格式错误的 JSON

**兼容性改善**
- 屏蔽率计算改用 `awk` 而非 `bc`（Android 上不可用）
- `grep` 样式改用 `-E` 以兼容 toybox
- 进程管理优先使用 PID 文件，不再依赖 `pgrep -x`
- 订阅 JSON 解析改为逐对象处理以提升健壮性
- 改善 toybox 的 `date +%N` fallback

**其他**
- 配置备份数量限制为最近 5 份
- 修正 README 的自动更新计划说明与 DNS 重定向解释

---

## 致谢

- [dnscrypt-proxy](https://github.com/dnscrypt/dnscrypt-proxy) by Frank Denis
- [dnscrypt-proxy-android](https://github.com/d3cim/dnscrypt-proxy-android) 提供参考
- [KernelSU](https://kernelsu.org) / [APatch](https://apatch.dev) 提供 WebUI 框架

---

## 许可

本模块依 MIT 许可「按现状」提供。dnscrypt-proxy 二进制文件依其自身许可（ISC）分发。
