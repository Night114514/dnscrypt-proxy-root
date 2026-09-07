# DNSCrypt Proxy Root WebUI 模块

[English](README.md) | [繁體中文](README.zh-TW.md) | [简体中文](README.zh-CN.md)

一个 systemless 的 Magisk/KernelSU/APatch 模块，在已 root 的 Android 设备上运行 **dnscrypt-proxy**，具备：

- **Systemless 加密 DNS**：通过 dnscrypt-proxy（DNSCrypt / DoH）
- **以 Magisk、KernelSU 与 APatch 为封装目标**；v0.9.1 的管理器／真机矩阵仍为
  [NOT RUN](REAL_DEVICE_ACCEPTANCE.md)，本版本不声称已经验证兼容性
- **两种明确集成模式**：默认 `strict` 全系统 Do53 拦截，或以 `upstream_only`
  与 Android Private DNS、VPN 及其他 DNS 前端共存
- **`strict` 模式的 IPv6 DNS 泄漏防护**：仅通过模块自有的 ip6tables 链阻挡
- **DNSSEC + NOLOG 解析器筛选**（`require_dnssec` / `require_nolog`）
- **自动二进制更新**：来自上游 releases
- **WebUI**：供 KernelSU/APatch 管理器使用（配置、日志、统计）
- **自定义屏蔽列表订阅**：具备安全的 URL 验证
- **多语言支持**（English、繁體中文、简体中文）
- **DNS 查询统计**仪表盘
- **屏蔽列表／允许列表**图形化管理
- **DNS 路径抽样检测** — 检查合成系统 DNS 查询是否出现在 dnscrypt-proxy 日志中 *(v0.7.0)*
- **服务监控 (watchdog) 与 Android 通知** — 服务异常停止时自动重启并通知 *(v0.7.0)*
- **WebUI 深色／浅色主题切换** *(v0.7.0)*
- **GitHub Actions CI/CD**：自动化模块发版

---

## 系统需求

- Android 7.0 以上（API 24+）
- 封装目标（v0.9.1 尚未完成真机验收）：**Magisk 20.4+**、**KernelSU 0.7.0+** 或
  **APatch 10596+**
- 更新器需要 `flock`（Android 7+ 的 Toybox 已提供；若系统命令不可用，将改用 root 管理器的 BusyBox）
- 内核需支持 **iptables NAT**（绝大多数设备均支持）
- WebUI 管理界面需要 KernelSU 或 APatch（Magisk 没有 WebUI；在 Magisk 上，action 按钮改为切换服务开关）

---

## 安装

1. 从 [Releases](https://github.com/Night114514/dnscrypt-proxy-root/releases) 下载最新的 `dnscrypt-proxy-root-vX.X.X.zip`。
2. 通过 **Magisk Manager**、**KernelSU Manager** 或 **APatch Manager** 刷入。
3. 重启。

安装程序会尝试下载符合检测架构的 dnscrypt-proxy 二进制文件；只有 release asset digest 与
二进制文件报告的版本均验证通过才会接受。下载失败会显示警告，但不会中止刷入；首次启动会在
启动 daemon 前重试，也可稍后通过 action 按钮或 KernelSU/APatch WebUI 重试。由于 root 管理器
会把模块暂存在 `/data/adb` 下，安装阶段刻意不执行真实配置／source `-check`；该检查延后到
首次启动，待 `/data/local/dnscrypt-proxy-root-runtime` 的受保护运行时副本创建后再执行。

> **v0.9.1 升级警告：**如果要覆盖安装 v0.9.0 或更旧版本，请先导出或记录配置、列表与
> 订阅。v0.9.0 允许 UID 3003 写入整个 config 目录；更早版本的布局也不符合 v0.9.1
> 强化后的迁移来源验证。安装程序因此会为这些版本一律安装经过审计的默认值；重启后
> 请重新应用配置。从 v0.6.0 至 v0.8.0 升级时必须重启，让内核安全清除无法区分来源的
> 旧式 IPv6 直接规则。

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

### 受保护的运行时副本

`/data/adb/modules/dnscrypt-proxy-root` 下的模块目录保存经过审计的配置模板、控制脚本、
WebUI，以及安装下载成功时通过 digest／版本验证的二进制文件。若该文件不存在，首次启动必须
先下载并验证后才会启动 daemon。服务会在 `/data/local/dnscrypt-proxy-root-runtime` 创建另一份
持久化运行树；这是文件副本，不是 bind mount 或 mount namespace overlay。模块会从这个可穿越
的运行树，以数值 UID 3003 直接执行 daemon 与 `-check`，因此不会由 root 进程要求上游程序解析
运行时配置，UID 3003 也不必穿越 root-only 的 `/data/adb` 路径。生命周期匹配仍接受上游 2.1.18
精确的可选 `-child` 形式，但 v0.9.1 的正常启动一开始就是最终 UID，不需要再次 exec。

运行时根目录与 `bin` 为 `root:root 0755`。正本 `config` 为 `root:root 0700`，五个受管输入文件
（以及存在时的 `subscriptions.json`）为 `root:root 0600`。每次启动前，模块会发布一份
`3003:root 0500` 的一次性 `active` 快照，其五个输入文件为 `3003:root 0400`；由于进程已经是最终
UID，快照会移除 `user_name`。可变的 query／NX log 与 resolver cache 位于 `3003:root 0700`
的 `data`，PID handshake 为 `3003:root 0600`。root 拥有的 `0600` `.layout-owner` 标记必须是
唯一一行以 LF 结尾的 `dnscrypt-proxy-root:5`。若现有目录没有标记、父路径／路径不安全、是符号
链接，或 ownership／mode 不符，服务会将其视为冲突并 fail-closed，不接管也不覆盖。卸载也只会
在相同路径、ownership、mode、事务状态与标记验证通过后删除该运行树。

### DNS 集成模式

集成模式以 root-only 模块状态保存，与 `dnscrypt-proxy.toml` 分离。状态文件不存在时默认
为 `strict`；内容无效或为符号链接时会 fail-closed。daemon 健康时切换模式不会重启：

```sh
sh /data/adb/modules/dnscrypt-proxy-root/scripts/dnscrypt-control.sh get-dns-mode
sh /data/adb/modules/dnscrypt-proxy-root/scripts/dnscrypt-control.sh set-dns-mode strict
sh /data/adb/modules/dnscrypt-proxy-root/scripts/dnscrypt-control.sh set-dns-mode upstream_only
```

默认 **`strict`** 模式：

- dnscrypt-proxy 监听于 `127.0.0.1:5354`。
- 在 `OUTPUT` 链中的 iptables NAT 链（`DNSCRYPT_PROXY`）会将所有对外的明文 DNS 查询（UDP/TCP port 53）DNAT 到 `127.0.0.1:5354`。
- 启用 `net.ipv4.conf.all.route_localnet=1`，让内核不会丢弃从 `OUTPUT` 链 DNAT 到 loopback 地址的数据包（没有这一项，重定向会完全失效）。
- dnscrypt-proxy 以 Android 的数值 AID_INET 身份（`3003`）运行。只有 effective UID 为 3003 的流量与 `127.0.0.0/8` loopback 范围使用 `RETURN` 规则，避免 bootstrap／netprobe 流量递归回代理。模块不再全局放行任何上游目标，因此普通 App 无法直接查询 bootstrap IP 来绕过保护。
- 由于 dnscrypt-proxy 仅监听 IPv4，IPv6 明文 DNS（port 53）会在模块自有的
  `DNSCRYPT_PROXY6` 链中阻挡。随机代际 token 会把两条模块链绑定到 root-only 的本次启动
  状态；未证明归属的同名链，以及 VPN、防火墙或其他模块的同型直接规则都会保留。
- 仅在确认精确 daemon、UID 3003、TCP/UDP listener，且有界、与上游无关的 canary 查询收到
  精确的本地合成 NXDOMAIN 响应后，才会保存并关闭 Android Private DNS；停止服务或离开
  `strict` 时会还原。

**`upstream_only`** 模式只维持 `127.0.0.1:5354` 的 dnscrypt-proxy listener，不安装全局
iptables/ip6tables 规则、不修改 `route_localnet`、也不更改 Android Private DNS。VPN 型过滤器
等本地 DNS 前端可将它作为上游；全系统防漏须由该前端负责，因此模块的 leak-test 会返回
`not_applicable`。

两种模式冷启动时，都会先在系统 DNS fail-open 状态，以 UID 3003 从一次性运行时快照执行
真实 `dnscrypt-proxy -check` source/cache 预检（硬上限 660 秒），再按上游 2.1.18 语义执行最长 3600 秒的 NetProbe，
并保留 30 秒 listener 稳定时间。仅在预检成功，且精确 PID、UID 3003、
`127.0.0.1:5354` 的 TCP LISTEN、UDP bound socket 与本地合成 DNS 响应有界探针
全部通过后才应用策略。
停用、移除或关机时会立即取消尚在执行的预检与 listener 等待，不会等待完整超时。

运行时配置正本仅允许 root 访问。daemon 只能读取每次新发布、由 UID 3003 拥有的只读运行快照，
并只可写入独立的 UID-3003 `data` 目录；模块主服务日志维持 root-only。staging、备份、验证、
回滚与提交都会重验文件类型、owner、mode 与 device/inode 身份。所有控制与更新入口也会拒绝
不安全的受管输入；query／NX-log 诊断会先以 UID 3003 复制有大小上限的快照，再交由 root 解析，
而不是在检查后重新打开 daemon 可控制的路径。

### skip_mount

`skip_mount` 文件刻意存在，因为本模块**不会**覆盖任何 system 分区文件。模块目录提供脚本、
WebUI、经过审计的模板，以及安装程序成功验证的二进制文件（如有）；daemon 则从
`/data/local/dnscrypt-proxy-root-runtime` 的独立持久化副本运行。本设计不使用 bind mount
或依赖 mount namespace；跳过 root 管理器的 system overlay mount 阶段，不会阻止创建该
`/data/local` 运行树。

### 自动更新（设备端）

每次开机时，`service.sh` 会在后台触发更新检查：

1. 查询 GitHub API 获取最新 dnscrypt-proxy release
2. 与当前安装版本比较
3. 若有新版，下载对应架构的 asset
4. 解压、验证并原子性替换受保护 `/data/local` 运行树内的二进制文件
5. 更新模块元数据

检查频率限制为每 24 小时一次（可通过 `DNSCRYPT_UPDATE_INTERVAL_SECONDS` 配置）。
只有检查成功、已是最新版，或新版完整安装并通过重启验证后，才会记录限流时间；网络、metadata、下载、验证、重启或回滚失败均可立即重试。

解压前，更新器会从 GitHub Release API 获取该精确 asset 的服务器端 SHA-256，并强制与下载文件比对。哈希缺失、格式错误、无法计算或不匹配都会中止安装。这是 GitHub HTTPS/API 信任边界内的 fail-closed 完整性检查，并非独立的 Minisign 发布者身份验证。

### CI/CD 自动更新（GitHub Actions）

计划任务工作流每月运行一次（每月 1 号，也可通过 `workflow_dispatch` 手动触发）：

1. 将上游 dnscrypt-proxy release 与独立记录的 `.github/upstream-version` 比较
2. 若检测到新的上游版本，递增模块本身独立的 `vX.X.X` patch 版本
3. 更新 `module.prop`、`update.json` 与上游版本记录
4. 构建仅含运行时文件的模块 ZIP，并以模块版本命名 GitHub Release

这让 Magisk 内置的模块更新器能通知用户有新版模块。

### DNS 泄漏检测 *(v0.7.0)*

DNS 测试页面新增了 **泄漏检测** 按钮。按下后，后端（`dnscrypt-control.sh leak-test`）会：

1. 生成 4 个随机的 `[a-z0-9-]` 子域名。
2. **通过系统 DNS 路径**解析每一个（而非直接连向 dnscrypt-proxy），模拟一般 App 受 iptables 重定向的查询。
3. 稍等片刻后，在 dnscrypt-proxy 的查询日志（以及 `nx.log`）中比对每个子域名。
4. 以单行 JSON 回报抽样日志可见性（为了 API 兼容而保留旧状态名称）：
   - `protected` — 4 个测试查询全都出现在 dnscrypt-proxy 日志中。
   - `partial` — 只有部分测试查询出现；请检查可能的绕过或查询／日志失败。
   - `leaking` — 测试查询全都未出现；请检查可能的绕过或查询／日志失败。

若查询日志未启用，会返回 `{"status":"error","reason":"query_log_disabled"}`，WebUI 会提示你启用。检测不会连接专用的第三方泄漏测试网站，但合成 DNS 查询仍会经过已配置的 DNS／上游路径，并可能出现在网络或上游 resolver 日志中。此抽样不涵盖 App 自有 DoH／DoT、所有 DNS 路径，也不能证明全系统没有泄漏。

### 服务监控 (Watchdog) 与通知 *(v0.7.0)*

`service.sh` 会启动一个后台 watchdog，每 60 秒检查服务一次：

- 若精确进程、UID、本地 TCP/UDP listener、本地 handler 有界探针或所选集成策略非人为地异常，会发出 Android
  通知，并以默认 60、120、240、480、900 秒的上限倍增退避重试。健康恢复、人为停止、
  正在启动或并行人工控制会重置延迟。飞行模式、Wi-Fi 中断与上游 resolver 离线只会
  标记为 `degraded`，不会重启仍健康的本地 daemon。
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
├── .github/
│   ├── upstream-version         # 独立记录的 dnscrypt-proxy 版本
│   └── workflows/               # CI/CD 自动化
│       ├── auto-update.yml      # 计划上游检查
│       ├── release.yml          # 经验证的模块版本发版
│       └── test.yml             # dash/BusyBox ash 测试与 ShellCheck
├── config/
│   └── dnscrypt-proxy.toml      # 随模块封装的默认模板
├── scripts/
│   ├── common.sh                # 共用工具函数
│   ├── dnscrypt-control.sh      # 服务控制与 WebUI API
│   ├── update-dnscrypt.sh       # 二进制更新器
│   └── watchdog.sh              # 单实例健康检查与自动恢复
├── tests/                        # POSIX sh 更新器回归测试与 mock
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

随模块封装的默认模板位于 `<模块目录>/config/dnscrypt-proxy.toml`。首次启动后，可编辑的
root-only 权威配置为 `/data/local/dnscrypt-proxy-root-runtime/config/dnscrypt-proxy.toml`；
daemon 会读取由它生成的只读运行快照。请通过 WebUI 修改权威配置，或以 root 直接编辑
该持久化路径；模块模板只用于初次创建运行树。主要设置：

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

- **尚未支持加密的 IPv6 DNS。** dnscrypt-proxy 被配置为仅监听 IPv4（`127.0.0.1:5354`）；为防止泄漏，IPv6 明文 DNS（port 53）会被*阻挡*而非重定向。在 `strict` 模式下，客户端必须支持并实际使用 IPv4 DNS fallback；否则仅支持 IPv6 的 DNS 客户端查询会失败。
- **需要 iptables NAT 支持。** 少数大幅精简的自定义 ROM 其内核缺少 NAT/`route_localnet`，透明重定向无法工作。
- DNS 重定向仅涵盖 port 53（Do53）。硬编码自身 DoH/DoT 端点的 App（例如某些浏览器）依设计绕过系统解析器，不受影响。
- `strict` 只拥有模块的 OUTPUT jump 与专用链；不声称涵盖 PREROUTING／热点客户端，
  也没有特定 VPN／fake-IP／TUN 的推测性豁免。
- `upstream_only` 刻意不提供全系统拦截或通用 DNS 泄漏判定。
- 持久化 `/data/local` 运行时副本的 SELinux 执行／访问行为，以及 Magisk、KernelSU、
  APatch 的生命周期兼容性（包括 Xiaomi 14T Pro／Android 16 参考环境）均为 **NOT RUN
  （未执行）**；本版本不声称兼容这些组合。
- Xiaomi 14T Pro／Android 16 与特定 VPN 产品的互操作性仍属人工验收项目；CI 验证的是可移植
  shell 行为，不能声称覆盖这些真机组合。请按[真机验收表](REAL_DEVICE_ACCEPTANCE.md)
  保留 argv／UID／socket／规则计数器与实际 DNS 出口证据；v0.9.1 各行目前明确标为
  **NOT RUN（未执行）**。

---

## 变更日志

### v0.9.1 (2026-09-07)

- 支持 dnscrypt-proxy 2.1.18 精确的可选 `-child` exec 形式，分别验证 UID 3003、实际
  TCP/UDP socket、本地合成 NXDOMAIN 响应与上游可达性。
- daemon 与 `-check` 均以 UID 3003 从经过标记及权限验证的持久化
  `/data/local/dnscrypt-proxy-root-runtime` 一次性快照运行；root-only 正本、UID-3003 只读
  运行快照及可变 data 分离。不安全或无标记的冲突会 fail-closed，卸载只删除验证过的自有树。
- 新增可事务切换的 `strict`／`upstream_only`、有界 source/cache 预检、符合上游语义的
  NetProbe 宽限、degraded/offline 状态与有上限的 watchdog 倍增退避。
- 使用 token 绑定的本次启动 ownership／adoption marker 与完整规则顺序验证，保留未证明归属的同名链
  或直接第三方规则，且仅在 listener 就绪后应用 strict 重定向。
- quick-mode 改为保守 TOML lexer、受保护 staging/inode 验证、原子替换及重启失败回滚；
  root-only 配置正本与 UID-3003 只读快照会隔离控制平面及 daemon 可写数据。
- 扩充 dash／BusyBox ash 的生命周期、更新器、socket、模式、防火墙与 TOML 测试。
- 升级时重置不符合新版迁移来源验证边界的 v0.9.0（含）以前配置；请先导出、重启，
  再重新应用。

### v0.9.0 (2026-08-29)

- 修复 v0.8 审计确认的备份清理、订阅累积、IPv6 规则、测速、watchdog、base64、空列表还原、下载 fallback、资源／日志路径与 resolver 空格问题。
- 强化精确 PID、DNS／防火墙 readiness、Android Private DNS 还原、模块升级配置迁移、停用／卸载清理与 AID_INET 专用运行身份。
- 上游压缩包验证改为强制 fail-closed，并加入二进制／配置验证、事务式重启与明确回滚状态。
- WebUI 现在会显示 shell 失败，列表采用原子写入；查询统计依官方 TSV return code 计算，不再把错误当成功或显示假数据。
- 按当前 KernelSU／APatch 实现重新验证元数据、ZIP 结构、生命周期、权限、WebUI bridge 与 Markdown 更新描述文件，并扩充 dash／BusyBox ash／JavaScript CI。

完整内容请参阅 [CHANGELOG.md](CHANGELOG.md)。

### v0.8.0 (2026-08-18)

- 将模块 `vX.X.X` Release 与独立追踪的上游 dnscrypt-proxy 版本分离。
- 修正更新限流：网络失败或 metadata 格式错误后可立即重试。
- 使用内核 `flock` 实现异常终止后可安全恢复的更新锁，并涵盖 BusyBox fallback 与旧锁迁移。
- 明确说明可选 checksum 比对不属于 Minisign 身份验证，且仍为 best-effort。
- 新增 dash 与 BusyBox ash 下的 POSIX `sh` 更新器测试，并加入 ShellCheck 与 GitHub Actions CI。
- 统一繁体中文 README 与 WebUI 的域名用语。
- 旧安装包仍固定使用不可变的 `v0.7.0` 更新描述文件，需手动安装一次 `v0.8.0`；本版已为后续更新切换至稳定描述文件网址。

### v0.7.0 (2026-07-23)

**新功能**
- **DNS 路径抽样检测**：新增 `leak-test` 命令与 WebUI 按钮，通过系统 DNS 路径解析随机子域名，并回报哪些样本出现在查询日志；为兼容而保留的 protected／partial／leaking 名称不能证明所有 DNS 路径都已加密。
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
- 新增 best-effort SHA256 比对，使用同一 release 的校验列表检查下载的 dnscrypt-proxy 压缩包；该列表未经签名验证，校验数据不可用时不会阻止安装
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
