# Easy VPN

**版本：1.0.19**

Easy VPN 是独立的 VPS 协议搭建与节点管理项目。启动后直接进入协议菜单，不包含 SSH 管理、系统安全、网络优化或 IP 测试等通用运维模块。


## 1.0.19 Reality SNI 候选扫描与筛选

- Reality、Hysteria 2、TUIC 部署前都会扫描一组经过筛选的公网 HTTPS 候选域名，并显示 TLS 握手中位延迟与三次测试的稳定性。
- 候选筛选要求 TLS 1.3、正常证书校验、HTTP/2、HTTP 2xx、没有跳转到其他域名，且三次探测至少两次通过；保留示例域名、IP 字面量和本地域名会被过滤。
- 用户可输入序号自行选择；输入 `0` 自动选择稳定性优先、延迟次之的综合最佳项；`R` 重新扫描；`Q` 取消。移除手动输入任意 SNI 的入口。
- 自动化部署模式会从通过筛选的候选中自动选择最佳项；如果没有候选通过，则取消该次部署，不会回退到未经验证的默认域名。
- 延迟表示 VPS 到候选网站的 TLS 握手测量值，不代表客户端到 VPS 的实际代理延迟。此筛选属于可用性检查，不保证某个候选在所有客户端网络都可达。


## 1.0.18 sing-box 慢速下载与断点续传修复

- HTTPS 下载单次最长等待从 120 秒提高到 600 秒，并设置低速保护；不会因链路较慢就过早终止正常下载。
- 下载中断后尝试从已接收的字节继续；如果下载源不支持 HTTP Range，则清空临时数据后重新完整下载，避免错误拼接。
- 下载期间只写入权限受限的临时文件，确认成功后才替换目标文件；连续失败会清理不完整文件。
- 保留 sing-box 的 SHA-256 检查流程；下载速度改善不代表可以跳过完整性验证。

## 1.0.17 端口跳跃取消与测试输出修复

- 修复在 Hysteria 2 部署时，于端口跳跃范围提示按 `Ctrl+D` 导致部署流程异常继续或退出的问题；现在明确取消本次部署，并返回主菜单。
- 将冒烟测试的 `OK` 提示移到所有回归测试之后，避免后续测试失败时提前显示成功。
- 发布签名仍为维护者可选功能；此版本未配置维护者公钥，不应声称已启用签名校验。

## 1.0.16 稳定性与下载源修复版

- **发布签名为可选维护者功能**：代码支持 ECDSA P-256 签名校验，但本 ZIP 未配置维护者公钥，也没有随包提供签名清单，因此不能声称当前版本已启用发布签名。
- **国内加速需要明确接受风险**：没有签名公钥时，第三方代理提供的安装脚本无法独立证明来自维护者。国内安装命令会显式设置 `EASY_VPN_ALLOW_UNSIGNED_PROXY=1`；安装器会在日志中记录此选择，并将其保存为权限为 `600` 的本地确认记录。若不愿承担该风险，请使用 GitHub 官方 HTTPS 源。
- **修复国内源状态卡住问题**：未明确确认风险时，不会保存国内代理设置；旧版本遗留的未确认 `china` 设置会自动切回官方 HTTPS 源。明确切换到官方源会撤销此前的未签名代理确认。
- **Hysteria 2 / TUIC 证书指纹固定**：Hysteria 2 分享链接增加 `pinSHA256` 参数；节点信息显示证书 SHA-256 指纹；导出的 Clash/Mihomo 配置对 Hysteria 2 和 TUIC 都加入 `fingerprint`。客户端因此能识别并拒绝中间人冒充的服务器，而不再是“完全不验证证书”。
- **不再盲目复用系统里的 sing-box**：优先使用本工具安装并校验过的内核；只有系统里的 `sing-box` 及其所在目录都归 root 所有、且组/其他用户不可写时才复用，否则改为下载并校验官方版本。
- `SINGBOX_VERSION` 必须是 `X.Y.Z` 稳定版本号，不再被原样拼进下载地址。
- 通过 `EASY_VPN_SERVICE_HARDENING=off` 关闭 systemd 沙盒时会明确警告并写入日志。
- 新增维护者工具 `tools/release.sh`（生成密钥、写入公钥、签名、自检），不会被安装到用户的 VPS 上。

## 1.0.14 快捷启动提示与命令兼容性

- 安装后同时提供大写 `VPN` 和小写 `vpn` 两个快捷命令，避免用户按界面提示输入大写命令却因 Linux 命令区分大小写而失败。
- 主菜单“0. 退出”旁增加绿色快捷启动提示；VPS 概况末尾也会重复提示，方便用户下次打开终端直接输入命令。
- 无交互终端安装完成时，也会提示使用 `VPN`（或 `vpn`）重新打开菜单。

## 1.0.13 国内加速安装

- 新增国内网络推荐的一键安装入口，使用 GH-Proxy 加速获取 Easy VPN 源码。
- 安装器会将加速源模式保存到 `/etc/easy-vpn/github-source-mode`，后续程序/协议清单检查也优先使用加速源；单个项目文件请求失败时会尝试官方 GitHub Raw 源。
- 仓库固定为 `yesok6/easy-vpn`，普通用户无需填写用户名、仓库名或配置其他仓库地址。

## 1.0.12 安装入口稳定性修复

- `install.sh` 和 `vpn` 快捷命令现在会分发 `--pipeline-reality`，并在非交互模式下调用 VLESS + Reality 自动部署；无法自动取得公网 IP 时可通过 `EASY_VPN_SERVER_IP` 显式提供地址。
- 安装快捷命令前自动创建目标父目录，兼容 `/usr/local/bin` 等目录不存在的精简系统。
- 三种协议的分享链接统一格式化主机地址：裸 IPv6 在 URI 中自动加方括号，节点信息保存为不带括号的地址，避免手动输入 IPv6 时链接损坏。
- 端口跳跃说明与 UFW/firewalld 的端口段规则行为保持一致。
- “查看节点信息”子菜单不再额外要求第二次回车。
- 复核并收紧 `/etc/fstab` 的 Swap 变更：备份先行、同目录原子替换、锁互斥，备份失败时拒绝写入；已有但未激活的自有 Swap 会检查并尝试恢复。
- 端口监听健康检查同时核对 systemd `MainPID`，避免将占用相同端口的 Nginx/Caddy 等其他进程误判为 sing-box 正常。
- 统一使用标准稳定版本号 `X.Y.Z`；预发布后缀与四段版本号会被拒绝，避免版本比较忽略后缀。
- 临时目录、更新备份、替换文件和快捷命令创建失败时会明确中止，避免继续运行于不完整状态或留下不必要的临时文件。
- 临时空间按任务分级预检：一般辅助操作至少 64 MiB，下载并解压 sing-box 内核至少 256 MiB；空间不足时会在下载/替换前停止。
- 磁盘空间预算统一在整数 KiB 中比较；安装目录和 sing-box 二进制目录明确设置为可由非特权服务账户遍历的权限，沙盒下的 `/var/lib/easy-vpn` 允许写入运行态数据。
- 保留此前的协议诊断、卸载、Swap 安全清理和更新后重新载入保护。

## 功能

- **VLESS + Reality**：基于 TCP 的代理协议。
- **Hysteria 2**：基于 QUIC/UDP，支持端口跳跃。
- **TUIC v5**：基于 QUIC/UDP，适合游戏和实时应用；本项目不提供 TUIC 多端口跳跃，端口跳跃仅供 Hysteria 2 使用。
- 查看节点信息、生成二维码、导出 Clash/Mihomo 配置、协议诊断、端口跳跃管理，以及检查 Easy VPN 程序版本、协议适配和 sing-box 内核版本。
- 菜单顶部显示主机名、系统与架构、内存总量和可用量、根分区总容量和可用容量、运行时间。

### 端口跳跃说明

- 端口跳跃仅提供给 Hysteria 2；TUIC v5 不显示无效的多端口跳跃选项。
- nftables 后端使用 `table inet` NAT，可在同时具备 IPv4/IPv6 的系统上处理两类流量。`inet` 有状态 NAT 需要 Linux 5.2+ 及内核/发行版对应支持；部署前会先用 `nft -c -f` 验证。验证不通过时，不会强行安装无效规则，Hysteria 2 会回退到单端口模式。
- 如果系统没有可用 nftables，则使用 iptables 后端；在 `iptables` 与 `ip6tables` NAT 都可用时会分别持久化 IPv4/IPv6 规则。只有 IPv4 NAT 可用时会明确提示“仅覆盖 IPv4”；如果节点地址为 IPv6 而 IPv6 NAT 不可用，则不会套用 IPv4 规则，会安全回退到单端口模式。
- nftables 与 iptables 共用 Easy VPN 自己的 systemd 恢复单元。该单元在开机时恢复持久化规则，但对 sing-box 使用 `Wants=` 弱依赖：即使可选端口跳跃恢复失败，也不会因此阻断 VLESS + Reality、TUIC 或 Hysteria 2 单端口服务启动。
- 新部署的端口跳跃会把本工具新增的 UFW/firewalld 放行规则记录到一个范围专用的 `.firewall` 清单，避免为每个端口创建状态小文件；升级兼容旧版逐端口规则记录。若清理中断，所有权清单会保留以便安全重试。
- VPS 服务商控制台中的云防火墙/安全组仍需允许所选 UDP 端口范围；本机规则不能替代云端规则。

## 启动后的菜单

```text
Easy VPN 协议搭建工具

主机概况：主机名 / 系统 / CPU 架构
内存：总量与可用量
根分区：总容量与可用容量
服务状态：运行中 / 未运行或未配置

1. 搭建 VLESS + Reality（TCP）
2. 搭建 Hysteria 2（QUIC / UDP，支持端口跳跃）
3. 搭建 TUIC v5（QUIC / UDP，适合实时应用）
4. 查看节点信息
5. 移除协议 / 清理全部
6. 检查更新（程序 / 协议 / 内核）
7. 节点工具与诊断（二维码 / Clash 配置 / 端口跳跃）
0. 退出
```

## 端口与证书说明

- VLESS + Reality 可使用标准 TCP 443 端口；服务以专用 `easy-vpn` 用户运行，并仅获得绑定低位端口所需的 `CAP_NET_BIND_SERVICE` 能力。80 也允许使用，但通常不会替代 HTTPS 443。
- Hysteria 2 和 TUIC v5 自签名证书采用最长 365 天有效期，SNI 从可用候选中选择。该调整是证书生命周期与配置卫生改进，不应视为规避流量识别的保证。
- 自签名证书无法被系统 CA 验证，所以分享链接仍带有 `insecure=1` / `allow_insecure=1`；为避免因此被中间人冒充，Hysteria 2 链接额外带有 `pinSHA256`，节点信息里也会显示证书指纹。请使用支持证书指纹固定的客户端，并确认它确实读取了该参数。TUIC 链接没有通用的固定参数，请在客户端的“证书指纹 / pin”设置里手动填入节点信息中的指纹；导出的 Clash/Mihomo 配置已自动包含。
- 证书 365 天后到期。多数客户端在“固定指纹”模式下不检查有效期，但仍建议到期前移除并重新部署协议，然后重新导入新的节点链接（指纹会随新证书变化）。

## 安装方式

### 一键安装（GitHub 官方源）

适用于 VPS 可以直接访问 GitHub Raw 的情况：

```bash
curl -fsSL "https://raw.githubusercontent.com/yesok6/easy-vpn/main/install.sh" | sudo bash
```

### 一键安装（国内网络加速）

国内网络可使用以下命令。安装脚本和后续 Easy VPN 项目文件同步会优先通过 GH-Proxy 获取；下载单个项目文件失败时，安装器会尝试回退到 GitHub 官方 Raw 源。加速源选择会保存到 `/etc/easy-vpn/github-source-mode`，之后菜单中的程序版本和协议清单检查也会沿用这一设置。

> **安全提醒：** 这条命令会从第三方加速服务取得将以 root 权限执行的初始脚本。本 ZIP 没有配置发布签名公钥，所以此模式无法独立验证代理返回的脚本确实来自维护者。只有在你明确接受这项信任风险时才使用；安装器会保存该选择，供之后更新时沿用。

```bash
curl -fsSL "https://gh-proxy.org/https://raw.githubusercontent.com/yesok6/easy-vpn/main/install.sh" | sudo env EASY_VPN_GITHUB_SOURCE_MODE=china EASY_VPN_ALLOW_UNSIGNED_PROXY=1 bash
```

仓库和分支已固定为本项目的 `yesok6/easy-vpn` 与 `main`，不需要填写用户名或仓库名。如果初始安装脚本本身无法从加速服务下载，可将链接里的 `https://gh-proxy.org/` 前缀去掉，改用 GitHub 官方 Raw 地址重新获取安装脚本。

**首次引导的信任问题：** 只有维护者配置了公钥、并发布匹配的签名文件时，安装器才会验证后续同步文件与更新；当前 ZIP 未配置公钥，所以当前版本尚未启用这层签名保护。第一次用 `curl | sudo bash` 取得的 `install.sh` 本身，无论如何都需要信任所选下载渠道。想要更稳妥，请先下载，再与项目发布说明中通过独立可信渠道公布的哈希比对后执行：

```bash
curl -fsSL "https://raw.githubusercontent.com/yesok6/easy-vpn/main/install.sh" -o install.sh
sha256sum install.sh        # 与项目发布页公布的 install.sh SHA-256 比对一致后再继续
sudo bash install.sh
```

### 可选的发布签名（进阶维护者功能）

当前 ZIP 的公钥为空，未附带 `SHA256SUMS` / `SHA256SUMS.sig`，所以当前发布并未启用签名验证。签名流程可以以后再配置，不是普通用户安装的必要步骤；不要为了让安装通过而伪造或随意填写公钥。

如果维护者准备长期启用签名，再按以下流程操作：

1. 在自己可信的维护电脑上运行 `bash tools/release.sh init-key`。私钥保存在 `~/.easy-vpn-release/release-private.pem`（权限 600）。**绝不要把私钥上传到 GitHub、放进 VPS 或发给任何人**，并做好离线备份。
2. 每次发布前运行 `bash tools/release.sh release`。它会把公钥写进 `install.sh`，生成 `SHA256SUMS` 和 `SHA256SUMS.sig` 并自检。
3. 将 `install.sh`、`lib/common.sh`、`modules/protocol.sh`、`protocol_catalog.json`、`VERSION`、`SHA256SUMS` 和 `SHA256SUMS.sig` 一起提交。以后修改任何受签名文件都必须重新签名。
4. 首次 `curl | sudo bash` 仍要信任你获取初始脚本的下载渠道；签名机制主要保护安装器后续获取的项目文件与更新。

### ZIP 安装（备用方式）

从 GitHub 下载 ZIP 并解压，在项目目录执行：

```bash
sudo bash install.sh
```

安装器会将运行文件安装到 `/opt/easy-vpn`，运行日志和配置状态放在 `/etc/easy-vpn`，并创建 `VPN` 与 `vpn` 两个快捷命令（默认位于 `/usr/local/bin/VPN` 与 `/usr/local/bin/vpn`）。交互式终端会直接显示协议菜单；通过管道安装时，安装器会尝试重新连接当前终端。如果没有可交互终端，则完成安装并提示之后输入 `VPN`（或 `vpn`），不会因 stdin EOF 假装进入菜单后闪退。

菜单第 6 项会分别检查 Easy VPN 程序版本、已实现协议适配版本，以及 sing-box 内核的最新稳定版本。发现程序更新时，选择 `1` 并输入 `Y` 才会更新；程序和协议适配已是最新版本时，可选择 `2` 并输入 `Y` 重装当前远端最新版，输入 `N` 则取消。sing-box 内核目前只检查并提示，不会随程序更新自动替换。

更新与重装都会先下载全部项目文件到临时目录，检查 HTTPS 下载结果、版本一致性、协议清单 JSON、Bash 语法和磁盘空间；随后备份旧程序文件，再逐个原子替换，最后进行模块加载健康检查。若切换或健康检查失败，会尝试恢复已替换的旧文件。配置、节点信息、证书、私钥和正在运行的 sing-box 服务不会被更新流程主动修改。更新前的程序文件备份保存在 `/etc/easy-vpn/backups/`。若自动回滚也失败，会明确提示保留的备份路径。此流程降低更新风险，但不能替代 VPS 快照/异地备份。

Easy VPN 项目更新默认使用固定的 `main` 分支，并沿用已保存的下载源设置；仅在安装器配置了发布公钥时，更新才会强制校验 `SHA256SUMS.sig` 和全部文件哈希。本 ZIP 当前没有配置公钥，官方源模式依赖 GitHub HTTPS，国内第三方代理模式依赖用户的明确风险确认。从本地 ZIP 解压目录安装属于用户自己提供的文件，不做远程签名校验。检查 sing-box 版本时优先使用 GitHub Release API；API 限流或不可用时，会回退读取 GitHub `releases/latest` 重定向并确认对应架构的资产存在。获取 SHA-256 时也会尝试 Release 页面公开的资产 digest；任何路径都不会在默认设置下跳过内核文件校验。

## 如何发布新协议与更新

新增协议不能只改 `protocol_catalog.json`：还必须在 `modules/protocol.sh` 中实现部署、配置校验、节点信息和移除逻辑，并通过测试。发布时同步更新 `install.sh` 中的 `CURRENT_VERSION`、`VERSION` 和 `protocol_catalog.json` 中的 `tool_version`，三个版本号必须一致。若维护者已启用发布签名，则运行 `bash tools/release.sh release` 重新生成签名并自检；未启用签名时不要伪造签名文件，并须如实说明当前发布的校验方式。最后再提交到 GitHub 默认分支。

用户进入菜单后选择第 6 项，Easy VPN 会检查远端版本、协议清单和 sing-box 内核版本。发现程序或协议实现更新时，会询问是否更新；确认后下载对应程序文件并重新载入时生效。清单里标记为未实现的计划协议不会被当作可用新协议。sing-box 内核的版本检查与 Easy VPN 程序更新分开处理，当前不会自动替换内核。

## 快捷启动

安装完成后，可在 VPS 终端输入 `VPN` 或 `vpn` 打开菜单。两个命令都支持；菜单顶部和“0. 退出”旁也会以绿色提示快捷启动方式。

## 安装路径

```text
/opt/easy-vpn/
├── install.sh
├── VERSION
├── protocol_catalog.json
├── lib/
│   └── common.sh
├── modules/
│   └── protocol.sh
└── bin/
    └── sing-box          # 部署时由 Easy VPN 下载并校验 SHA-256；仅当系统已有仅 root 可写的 sing-box 时才可能复用

/etc/easy-vpn/
├── install.log
├── state/                # 运行状态与资源所有权记录
├── backups/              # 更新/重装前的程序备份
├── port-hop/             # .nft/.iptables 规则数据与 .firewall 所有权清单
└── sing-box/             # 配置、节点信息及协议所需的证书/密钥等，文件随安装情况变化

/etc/systemd/system/easy-vpn-port-hop.service  # 持久化规则恢复服务（启用端口跳跃时）
```

同时会创建 `easy-vpn-sing-box.service` systemd 服务和专用的 `easy-vpn` 系统用户/用户组。更新不会自动删除安装目录里的未知文件或其他旧模块，避免误删共享目录上的文件。具体配置会随启用的协议变化；节点凭据和私钥不要公开分享。

## VPS 资源显示说明

- 内存总量读取 `/proc/meminfo` 中的 `MemTotal`。
- 内存可用量读取 `MemAvailable`，比单独看 `MemFree` 更能反映新任务可用的内存。
- 磁盘容量显示根分区 `/` 的结果，不包含其他挂载盘。
- 这些数值是菜单刷新时的快照，仅用于部署前参考，不保证任意负载下都能稳定运行。

## 项目文件

```text
install.sh
VERSION
README.md
protocol_catalog.json
SHA256SUMS            # 发布时由 tools/release.sh 生成
SHA256SUMS.sig        # 对 SHA256SUMS 的 ECDSA 签名（base64）
lib/common.sh
modules/protocol.sh
tools/release.sh      # 维护者发布/签名工具（不会安装到 VPS）
tests_smoke.sh
```

`lib/common.sh` 是协议模块依赖的公共函数库；本项目包不包含其他通用运维模块。

## 安全设计与已知限制

已做到：

- 内核 `sing-box` 下载后强制校验 SHA-256；服务以专用低权限账户运行，并启用 systemd 沙盒加固。
- 程序更新有防降级、原子替换和自动回滚；只有维护者配置发布公钥后才会强制执行签名校验。
- 未配置公钥时，第三方加速源必须由用户明确确认风险；确认会被本地保存，切回官方源可撤销。
- Hysteria 2 / TUIC 的自签名证书支持指纹固定，抵御中间人冒充。
- 复用系统 sing-box 前检查文件和目录的所有权与写权限。

仍需你知道的限制：

- 首次 `curl | sudo bash` 取得的 `install.sh` 无法被自身验证，请按上文先核对哈希。
- sing-box 的 SHA-256 来自与二进制相同的 GitHub 发布源，它能防下载损坏和传输篡改，但防不了上游发布本身被投毒。
- 流水线模式 `--pipeline-reality` 会把 UUID、公钥和分享链接打印到标准输出；在 CI 或会保存日志的环境里使用时，请对输出做保密处理。
- 私钥一旦泄露，攻击者即可签发恶意更新；请妥善保管并按需轮换。
- 本工具不能替代 VPS 快照、云防火墙/安全组配置和系统自身的安全更新。

## 验证

```bash
bash -n install.sh
bash -n lib/common.sh
bash -n modules/protocol.sh
bash -n tools/release.sh
jq empty protocol_catalog.json
sudo bash tests_smoke.sh
```

> **升级提醒：** Easy VPN 使用新的安装目录、配置目录、服务名和系统账户，不会自动搬迁旧版安装中的配置。若 VPS 上已经运行过旧版协议服务，请先备份配置并确认旧服务状态，避免两套服务争用相同端口。Easy VPN 不会自动删除旧版文件或服务。
