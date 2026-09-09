# DNSCrypt Proxy Root

在已 Root 的 Android 设备上运行 dnscrypt-proxy，提供加密 DNS、受管理的域名／IP 列表与本地 DNS 上游。

[下载 Release](https://github.com/Night114514/dnscrypt-proxy-root/releases) ·
[English](README.md) · [繁體中文](README.zh-TW.md) · [更新记录](CHANGELOG.md)

> **v0.9.2 状态：**模块跟踪 dnscrypt-proxy 2.1.18。dash、BusyBox ash、JavaScript、lint、
> 回滚及打包自动测试不能取代 Android 真机测试；v0.9.2 的
> [真机验收矩阵](REAL_DEVICE_ACCEPTANCE.md) 仍明确标为 **NOT RUN**。请勿假定所有设备、
> Root 管理器、VPN 或 DNS 前端均已验证兼容。

## 选择集成模式

| | `strict`（默认） | `upstream_only` |
|---|---|---|
| 适用场景 | 由本模块接管普通系统 Do53 | 由另一个 DNS 前端或代理负责接管与分流 |
| 本地服务 | `127.0.0.1:5354` | `127.0.0.1:5354` |
| IPv4 Do53 | 重定向到本地服务；保留 daemon UID／loopback 豁免 | 不创建本模块的全局重定向 |
| IPv6 Do53 | 通过本模块自有链阻止；保留 daemon UID 豁免 | 不创建本模块的阻止策略 |
| Android 私人 DNS | strict 策略运行时保存并关闭；停止或离开模式时恢复 | 保留／恢复原设置 |
| 与其他 DNS 接管者共存 | 需核对规则顺序与回路 | 需在前端明确指定本模块为上游 |

`upstream_only` 不会自动让所有 App 使用本模块。前端必须能在自己的网络 namespace 中连接
`127.0.0.1:5354`，并自行完成 DNS 接管／分流。

集成模式与 WebUI 的解析器 preset 不同：`strict`／`upstream_only` 控制 Android 路由策略，
`quick-mode` 选择解析器与协议偏好。

## 系统要求

- 项目目标为 Android 7.0+；实际支持取决于设备与 Root 管理器验收。
- Magisk、KernelSU 或 APatch 模块环境。
- `strict` 需要可用的 iptables／ip6tables、NAT、owner／comment 等内核能力。
- 需要 root shell 的锁与诊断命令；部分命令可由 Root 管理器 BusyBox 提供后备。
- 安装／核心更新及首次获取解析器来源时可能需要连接 GitHub。

WebUI 供 KernelSU／APatch 使用；Magisk 用户可通过 action 按钮与 root shell 控制。

| 设备 ABI | 上游 Release asset |
|---|---|
| arm64-v8a | `android_arm64` |
| armeabi-v7a | `android_arm` |
| x86_64 | `android_x86_64` |
| x86 | `android_i386` |

## 安装与升级

1. 从 [Releases](https://github.com/Night114514/dnscrypt-proxy-root/releases) 下载 `dnscrypt-proxy-root-v0.9.2.zip`。
2. 在 Root 管理器安装模块。
3. 重启设备。
4. 检查完整服务状态，再选择符合 DNS 架构的集成模式。

模块 ZIP 不包含 dnscrypt-proxy 可执行文件。安装时会尝试下载正确的官方 asset，并核对 Release digest
与可执行文件报告的版本。下载失败会警告但不会放弃模块安装；首次启动或稍后手动更新可以重试。

> **从 v0.9.0 或更旧版本升级：**请先导出或记录配置、列表与订阅。旧版布局不符合强化后的迁移
> 来源边界，安装程序会改用经过审计的默认值；重启后再应用所需输入。从 v0.6.0–v0.8.0 直接升级
> 必须重启，以安全清除无法辨认来源的旧式 per-boot IPv6 规则。可信的 v0.9.1 canonical generation
> 会由 v0.9.2 安装程序保留。

## 首次验证与常用操作

以下命令在 **Android root shell** 执行；使用 ADB 时先进入 `adb shell`，再执行 `su`。

```sh
DPR_CTL=/data/adb/modules/dnscrypt-proxy-root/scripts/dnscrypt-control.sh

sh "$DPR_CTL" status
sh "$DPR_CTL" get-dns-mode
sh "$DPR_CTL" logs
```

进程存在不等于 DNS 防护正常。请同时检查 `healthy`、`service_state`、`listener`、`local_dns`、
`firewall`、`upstream`、`config_apply_state` 与 `start_failure`。

| 状态示例 | 含义 |
|---|---|
| `healthy` | 本地 DNS 与所选策略通过检查；上游探测仍可能为 unknown |
| `degraded` | 本地服务／策略正常，但最近上游探测失败 |
| `starting` | 仍在有时限的启动／预检阶段 |
| `policy_fault` | 进程可能存在，但所选系统策略未通过验证 |
| `stopped`／`start_*` | 服务已停止，或在指定启动阶段失败 |

常用操作：

```sh
sh "$DPR_CTL" start
sh "$DPR_CTL" stop
sh "$DPR_CTL" restart

sh "$DPR_CTL" set-dns-mode upstream_only
sh "$DPR_CTL" set-dns-mode strict
```

以上是可选操作，不需要依次全部执行。健康 daemon 运行时切换模式只更改所选 Android 策略，无需
重新创建进程；daemon 停止时切换只保存选择，不会自行启动服务。

## WebUI 与 canonical generation

在 KernelSU／APatch 模块页打开 WebUI，可查看后端真实状态、编辑 TOML／受管理列表、选择解析器、
管理订阅、查看统计与日志、执行有界诊断、更新核心，以及导出／导入 generation。TOML 控件是纯文本编辑器。

v0.9.2 WebUI 由无依赖的 `webui/src/` 源码构建；提交到 `webroot/` 的五个文件可确定性重建，
不再包含 development React bundle 或远程分析。桥接只允许列明的控制操作；路径、所有权、锁、
验证与回滚仍由 root 后端强制执行。

| 路径 | 用途 |
|---|---|
| `/data/adb/modules/dnscrypt-proxy-root/config/` | 随模块提供的审计模板；不是实时单一事实来源 |
| `/data/local/dnscrypt-proxy-root-runtime/config/` | Canonical TOML、四份列表及订阅 |
| `/data/local/dnscrypt-proxy-root-runtime/active/` | 当前 daemon generation 使用的只读 snapshot |
| `/data/local/dnscrypt-proxy-root-runtime/data/` | 解析器 cache 与已配置的 query／NX logs |

不要直接编辑 `active/`；请使用 WebUI／后端，或以 root 谨慎编辑 canonical 路径。

保存与应用有意分开：

- **配置文件－保存（待应用）：**验证后通过原子替换更新 canonical TOML；成功消息不会改变运行中 snapshot。
- **配置文件－保存并重启：**先保存，再请求重启；如果重启失败，已保存 TOML 仍是 canonical，界面会明确报错。
- **受管理列表－保存（待应用）：**更新一份 canonical 列表而不重启。
- **受管理列表－保存并应用：**服务运行且没有 canonical 输入已处于待应用状态时，才会以新
  generation 重启；如果启动失败，后端恢复上一份 canonical 列表，再启动已知可工作的 generation。
  如果已有待应用或不可用的 generation，后端会在改动所选列表前拒绝操作；请先重启或恢复该代配置。
  如果连 rollback replace 也失败，后端会保留已验证的旧列表备份，并报告其完整路径供手动恢复。
- `status.config_apply_state` 为 `pending`、`applied` 或 `unavailable`；不要从“保存成功”推断已应用。

列表读取与写入使用同一个 canonical 后端 API。WebUI 不会再读取模块模板，却写入另一个 runtime 路径。

## 备份与恢复

`export-config` 输出一份严格的 generation manifest（schema v2），包含 TOML、四份受管理列表与订阅。
Android 集成模式有意保持独立，导入不会修改它。

导入只接受精确的 v1／v2 字段布局，逐字段限制大小，在私有 staging 目录解码并保护所有内容，
并让 dnscrypt-proxy 连同 staged lists 验证整份 generation。通过后才开始 canonical commit。完整旧
generation 与 recovery marker 会保留；任何 commit 失败或中断都会恢复所有 canonical 输入。
待处理的恢复会在下一个 control action（包括 `status`）dispatch 前完成。成功导入后仍需重启才能应用。

订阅使用严格 JSON 数组。每个条目必须恰好包含一个 HTTPS `url` 字符串及一个 `enabled` 布尔值
（两个字段顺序不限）；未知／重复字段、转义或不安全的 URL，以及类型错误的布尔值都会被拒绝。
普通多行 JSON 空白可以使用。

升级或大幅修改前请先备份；不要把 PID、锁、active snapshot 或日志等 transient 文件放入配置备份。

## 更新 dnscrypt-proxy

```sh
sh "$DPR_CTL" check-update
sh "$DPR_CTL" update
```

- **模块更新**由 Root 管理器安装 Release ZIP，并可能要求重启。
- **核心更新**使用 WebUI 或 `update`；`check-update` 只比较版本。
- 启动会触发后台核心检查，成功检查受默认 24 小时间隔限制；这不是每 24 小时唤醒的常驻任务。
- 更新器验证 Release asset digest、可执行文件版本、staged configuration 与 rollback 路径。GitHub
  Release checksum 只证明与该发布渠道一致，不是独立发布者签名。
- 中断时只清理该进程准确拥有的 `tmp/update-<pid>` workspace。

## 诊断、隐私与路由限制

- `strict` 主要控制普通 Do53，不能保证拦截 App 自有 DoH／DoT、所有 VPN DNS 路径或其他 namespace。
- strict 阻止 IPv6 Do53，而不是重定向到 IPv6 listener；这与回答 AAAA 或使用 IPv6 上游不同。
  IPv6-only 网络仍需真机验收。
- 启动／恢复会先移除旧策略，等待本地 DNS 预检成功后再添加 strict 规则；该阶段有意 fail-open。
- 默认模板启用 query log，用于统计与抽样路径检查。分享前请检查域名数据。解析器 `require_nolog`
  是服务器筛选条件，不代表本地没有 query log。
- `leak-test` 只检查四个生成样本是否出现在 query／NX logs；兼容用的
  `protected`／`partial`／`leaking` 名称不能证明所有 DNS 路径状态，在 `upstream_only` 下也不适合
  判断全系统接管。
- `strict` 下 `dns-test` 的指定目标 DNS 查询会受当前重定向策略影响。结果标为
  `comparison_scope=policy_affected`，不是直接 DNS bypass 测量。

## 常见问题

| 情况 | 首先检查 |
|---|---|
| 安装后没有启动 | `status.start_failure`、下载网络及 `logs` |
| 与 VPN／另一个 DNS 模块共存后异常 | 谁接管 Do53、是否应使用 `upstream_only`、上游地址与回路 |
| 加入允许列表仍被拦截 | Canonical 列表、`config_apply_state`、其他前端／上游是否另有过滤 |
| 有进程但策略不正常 | `service_state`／`firewall`，不要只看 `running` |
| 停用／删除 | 先执行 `stop` 并核对结果，再在管理器停用／删除并按要求重启 |

watchdog 会检查本地服务与所选策略；人为停止不视为故障，上游暂时离线也不会造成无限重启。

报告问题时请附模块／Root 管理器／Android 版本、集成模式、相关错误与已删除私人信息的日志。
不要公开订阅 token 或未经检查的查询记录。

## 开发与验证

常用仓库检查：

```sh
node webui/build.mjs --check
node tests/test-webui-bridge.js
dash tests/test-update-dnscrypt.sh
dash tests/test-dnscrypt-control.sh
busybox ash tests/test-update-dnscrypt.sh
busybox ash tests/test-dnscrypt-control.sh
```

`node webui/build.mjs` 会按照构建脚本声明，有意以确定性文件替换 `webroot/`。CI 也检查 shell／
JavaScript 语法、ShellCheck、两套 shell 矩阵、release metadata、ZIP 权限／排除规则与许可证文件。
这些都不是 Android 安装、SELinux、firewall、VPN 或实际数据包路径的证据；真机结果必须记录在
[REAL_DEVICE_ACCEPTANCE.md](REAL_DEVICE_ACCEPTANCE.md)。

自动发布只 checkout 通过 reusable tests 的准确事件 SHA；如果 `master` 已前进就中止，避免用更新的
未测试 branch tip 构建 tag／ZIP。

## 许可证与第三方内容

项目自有代码采用 [MIT License](LICENSE)。第三方内容保留各自条款，详见
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) 与 [LICENSES/](LICENSES/)。

模块 ZIP 包含一份原样 Magisk installer script，依 GPL-3.0-only 提供，并列出固定 source commit／
blob provenance。dnscrypt-proxy 可执行文件不预装在 ZIP 内，但更新器会在设备上安装官方 ISC 许可的
2.1.18 asset，因此 ZIP 也包含对应 ISC notice。
