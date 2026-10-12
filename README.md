# Easy VPN

**版本：1.0.13**

Easy VPN 是独立的 VPS 协议搭建与节点管理项目。启动后直接进入协议菜单，不包含 SSH 管理、系统安全、网络优化或 IP 测试等通用运维模块。

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
- Hysteria 2 和 TUIC v5 自签名证书采用最长 365 天有效期，SNI 从可用候选中选择；分享链接仍会明确标记使用自签名证书需要跳过证书验证。该调整是证书生命周期与配置卫生改进，不应视为规避流量识别的保证。

## 安装

从 GitHub 下载 ZIP 并解压，在项目目录执行：

```bash
sudo bash install.sh
```

安装器会将运行文件安装到 `/opt/easy-vpn`，运行日志和配置状态放在 `/etc/easy-vpn`，并创建快捷命令 `vpn`（默认位于 `/usr/local/bin/vpn`）。交互式终端会直接显示协议菜单；通过管道安装时，安装器会尝试重新连接当前终端。如果没有可交互终端，则完成安装并提示之后运行 `vpn`，不会因 stdin EOF 假装进入菜单后闪退。

### 一键安装

```bash
curl -fsSL "https://raw.githubusercontent.com/yesok6/easy-vpn/main/install.sh" | sudo env EASY_VPN_GITHUB_SOURCE_MODE=china bash
```

### 一键安装（国内网络加速）

vps在国内网络推荐使用以下命令。安装脚本和后续 Easy VPN 项目文件同步会优先通过 GH-Proxy 获取；下载单个项目文件失败时，安装器会尝试回退到 GitHub 官方 Raw 源。加速源选择会保存到 `/etc/easy-vpn/github-source-mode`，之后菜单中的程序版本和协议清单检查也会沿用这一设置。

```bash
curl -fsSL "https://gh-proxy.org/https://raw.githubusercontent.com/yesok6/easy-vpn/main/install.sh" | sudo env EASY_VPN_GITHUB_SOURCE_MODE=china bash
```

仓库和分支已固定为本项目的 `yesok6/easy-vpn` 与 `main`，不需要填写用户名或仓库名。GH-Proxy 是第三方公共加速服务；如果初始安装脚本本身无法从加速服务下载，可将链接里的 `https://gh-proxy.org/` 前缀去掉，改用 GitHub 官方 Raw 地址重新获取安装脚本。

菜单第 6 项会分别检查 Easy VPN 程序版本、已实现协议适配版本，以及 sing-box 内核的最新稳定版本。发现程序更新时，选择 `1` 并输入 `Y` 才会更新；程序和协议适配已是最新版本时，可选择 `2` 并输入 `Y` 重装当前远端最新版，输入 `N` 则取消。sing-box 内核目前只检查并提示，不会随程序更新自动替换。

更新与重装都会先下载全部项目文件到临时目录，检查 HTTPS 下载结果、版本一致性、协议清单 JSON、Bash 语法和磁盘空间；随后备份旧程序文件，再逐个原子替换，最后进行模块加载健康检查。若切换或健康检查失败，会尝试恢复已替换的旧文件。配置、节点信息、证书、私钥和正在运行的 sing-box 服务不会被更新流程主动修改。更新前的程序文件备份保存在 `/etc/easy-vpn/backups/`。若自动回滚也失败，会明确提示保留的备份路径。此流程降低更新风险，但不能替代 VPS 快照/异地备份。

Easy VPN 项目更新默认使用固定的 `main` 分支，并沿用已保存的国内加速源设置。检查 sing-box 版本时优先使用 GitHub Release API；API 限流或不可用时，会回退读取 GitHub `releases/latest` 重定向并确认对应架构的资产存在。获取 SHA-256 时也会尝试 Release 页面公开的资产 digest；任何路径都不会在默认设置下跳过内核文件校验。

## 如何发布新协议与更新

新增协议不能只改 `protocol_catalog.json`：还必须在 `modules/protocol.sh` 中实现部署、配置校验、节点信息和移除逻辑，并通过测试。发布时同步更新 `install.sh` 中的 `CURRENT_VERSION`、`VERSION` 和 `protocol_catalog.json` 中的 `tool_version`，三个版本号必须一致，再提交到 GitHub 默认分支。

用户进入菜单后选择第 6 项，Easy VPN 会检查远端版本、协议清单和 sing-box 内核版本。发现程序或协议实现更新时，会询问是否更新；确认后下载对应程序文件并重新载入时生效。清单里标记为未实现的计划协议不会被当作可用新协议。sing-box 内核的版本检查与 Easy VPN 程序更新分开处理，当前不会自动替换内核。

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
    └── sing-box          # 部署时由 Easy VPN 安装；若系统已有则可能复用系统版本

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
lib/common.sh
modules/protocol.sh
tests_smoke.sh
```

`lib/common.sh` 是协议模块依赖的公共函数库；本项目包不包含其他通用运维模块。

## 验证

```bash
bash -n install.sh
bash -n lib/common.sh
bash -n modules/protocol.sh
jq empty protocol_catalog.json
sudo bash tests_smoke.sh
```

> **升级提醒：** Easy VPN 使用新的安装目录、配置目录、服务名和系统账户，不会自动搬迁旧版安装中的配置。若 VPS 上已经运行过旧版协议服务，请先备份配置并确认旧服务状态，避免两套服务争用相同端口。Easy VPN 不会自动删除旧版文件或服务。
