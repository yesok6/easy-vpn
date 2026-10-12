#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"
require_root

CONF_DIR="${EASY_VPN_CONF_DIR:-${EASY_VPN_ETC}/sing-box}"
CONF_FILE="${CONF_DIR}/config.json"
NODE_INFO_FILE="${CONF_DIR}/node_info.txt"
PROTOCOL_NODE_INFO_DIR="${CONF_DIR}"
SERVICE_UNIT="easy-vpn-sing-box.service"
SYSTEMD_DIR="${EASY_VPN_SYSTEMD_DIR:-/etc/systemd/system}"
SERVICE_FILE="${EASY_VPN_SERVICE_FILE:-${SYSTEMD_DIR}/${SERVICE_UNIT}}"
SINGBOX_BIN=""
PROTOCOL_CATALOG_FILE="${EASY_VPN_ROOT}/protocol_catalog.json"
PROTOCOL_BRANCH="${EASY_VPN_BRANCH:-main}"
PROTOCOL_CATALOG_URL="${EASY_VPN_PROTOCOL_CATALOG_URL:-https://raw.githubusercontent.com/${EASY_VPN_GITHUB_USER:-yesok6}/${EASY_VPN_GITHUB_REPO:-easy-vpn}/${PROTOCOL_BRANCH}/protocol_catalog.json}"

resolve_singbox() {
    if [[ -n "${SINGBOX_BIN:-}" && -x "$SINGBOX_BIN" ]]; then return 0; fi
    if command_exists sing-box; then
        SINGBOX_BIN="$(command -v sing-box)"
        return 0
    fi
    if [[ -x "${EASY_VPN_ROOT}/bin/sing-box" ]]; then
        SINGBOX_BIN="${EASY_VPN_ROOT}/bin/sing-box"
        return 0
    fi
    return 1
}

github_release_api_json() {
    local endpoint="$1"
    curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
        --connect-timeout 10 --max-time 30 \
        -H 'Accept: application/vnd.github+json' \
        -H 'X-GitHub-Api-Version: 2022-11-28' \
        "https://api.github.com/repos/SagerNet/sing-box/${endpoint}"
}

# Resolve the Latest stable tag without the API. GitHub redirects /releases/latest
# to /releases/tag/<tag>; HEAD also verifies the architecture-specific asset exists.
singbox_latest_version_from_redirect() {
    local arch="$1" latest_url tag version asset
    latest_url=$(curl --fail --silent --show-error --location --head --proto '=https' --tlsv1.2 \
        --connect-timeout 10 --max-time 30 --output /dev/null --write-out '%{url_effective}' \
        'https://github.com/SagerNet/sing-box/releases/latest') || return 1
    [[ "$latest_url" =~ /releases/tag/(v?[0-9]+\.[0-9]+\.[0-9]+)/?$ ]] || return 1
    tag="${BASH_REMATCH[1]}"
    version="${tag#v}"
    [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
    asset="sing-box-${version}-linux-${arch}.tar.gz"
    curl --fail --silent --show-error --location --head --proto '=https' --tlsv1.2 \
        --connect-timeout 10 --max-time 30 --output /dev/null \
        "https://github.com/SagerNet/sing-box/releases/download/v${version}/${asset}" || return 1
    printf '%s\n' "$version"
}

latest_singbox_version() {
    local arch releases_json version
    case "$(uname -m)" in
        x86_64) arch=amd64 ;;
        aarch64) arch=arm64 ;;
        *) return 1 ;;
    esac

    # Preferred path: use the API to select the newest stable release that has
    # the desired architecture asset. If rate-limited/unavailable, use GitHub's
    # non-API Latest redirect and verify the target asset with a HEAD request.
    if releases_json=$(github_release_api_json 'releases?per_page=10' 2>/dev/null); then
        version=$(jq -er --arg arch "$arch" '
            [
                .[]
                | select((.draft // false) == false and (.prerelease // false) == false)
                | .tag_name as $tag
                | select(($tag | type) == "string" and ($tag | test("^v[0-9]+\\.[0-9]+\\.[0-9]+$")))
                | select(any(.assets[]?; .name == ("sing-box-" + ($tag | sub("^v"; "")) + "-linux-" + $arch + ".tar.gz")))
                | $tag
            ]
            | first // empty
            | sub("^v"; "")
        ' <<<"$releases_json" 2>/dev/null) || version=""
        if [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            printf '%s\n' "$version"
            return 0
        fi
    fi

    version=$(singbox_latest_version_from_redirect "$arch") || {
        echo -e "${YELLOW}[提示]${PLAIN} GitHub Release API 不可用，且 Latest 重定向备用查询失败。" >&2
        return 1
    }
    printf '%s\n' "$version"
}

# GitHub's release HTML exposes each asset's published sha256 digest. Use this
# unauthenticated page only when the REST API is unavailable or omits a digest.
fetch_release_asset_digest_from_html() {
    local version="$1" asset="$2" html checksum
    local html_dir
    html_dir=$(make_temp_dir singbox-release-html) || return 1
    html="${html_dir}/release.html"
    if ! curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
        --connect-timeout 10 --max-time 30 -o "$html" \
        "https://github.com/SagerNet/sing-box/releases/expanded_assets/v${version}"; then
        rm -rf -- "$html_dir"
        return 1
    fi
    checksum=$(awk -v asset="$asset" '
        BEGIN { RS="</li>" }
        index($0, asset) {
            s=$0
            while (match(s, /sha256:[[:xdigit:]]+/)) {
                h=substr(s, RSTART+7, RLENGTH-7)
                if (length(h) == 64) { print h; exit }
                s=substr(s, RSTART+RLENGTH)
            }
        }
    ' "$html")
    rm -rf -- "$html_dir"
    [[ "$checksum" =~ ^[A-Fa-f0-9]{64}$ ]] || return 1
    printf '%s\n' "$checksum"
}

fetch_release_asset_digest() {
    local version="$1" asset="$2" release_json checksum
    if release_json=$(github_release_api_json "releases/tags/v${version}" 2>/dev/null); then
        checksum=$(jq -r --arg name "$asset" '
            .assets[]? | select(.name == $name) | (.digest // empty)
        ' <<<"$release_json" 2>/dev/null | sed -n '1p')
        checksum="${checksum#sha256:}"
        if [[ "$checksum" =~ ^[A-Fa-f0-9]{64}$ ]]; then
            printf '%s\n' "$checksum"
            return 0
        fi
    fi
    fetch_release_asset_digest_from_html "$version" "$asset"
}

fetch_checksums_file() {
    local version="$1" out="$2" name url asset
    asset="${SINGBOX_CHECKSUM_ASSET:-sing-box-${version}-linux-amd64.tar.gz}"
    for name in \
        sha256sums.txt \
        sha256sums \
        SHA256SUMS \
        checksums.txt \
        checksums.sha256 \
        "${asset}.sha256" \
        "${asset}.sha256.txt"; do
        url="https://github.com/SagerNet/sing-box/releases/download/v${version}/${name}"
        rm -f "$out"
        if curl --fail --silent --location --proto '=https' --tlsv1.2 \
            --connect-timeout 10 --max-time 30 -o "$out" "$url"; then
            [[ -s "$out" ]] && return 0
        fi
    done
    return 1
}

extract_singbox_checksum() {
    local file="$1" asset="$2"
    awk -v asset="$asset" '
        function valid_hash(s) {
            return length(s) == 64 && s !~ /[^0-9A-Fa-f]/
        }
        {
            # GitHub/发布者可能提供 CRLF 文件；在两种格式共用的入口处去掉行尾回车。
            sub(/\r$/, "", $0)
            # GNU coreutils 风格：<hash>  <filename> 或 <hash> *<filename>
            hash=$1
            name=$2
            sub(/^\*/, "", name)
            if (valid_hash(hash) && name == asset) {
                print hash
                exit
            }

            # BSD 风格：SHA256 (filename) = <hash>
            prefix="SHA256 (" asset ") = "
            if (index($0, prefix) == 1) {
                hash=substr($0, length(prefix) + 1)
                if (valid_hash(hash)) {
                    print hash
                    exit
                }
            }
        }
    ' "$file"
}

resolve_singbox_checksum() {
    local version="$1" asset="$2" checksum_file="$3" checksum
    local SINGBOX_CHECKSUM_ASSET="$asset"

    if [[ "${EASY_VPN_SKIP_SINGBOX_VERIFY:-0}" == "1" ]]; then
        echo -e "${YELLOW}[警告]${PLAIN} EASY_VPN_SKIP_SINGBOX_VERIFY=1：已跳过 sing-box SHA-256 校验，仅适用于明确完成人工核验的应急场景。" >&2
        log_action "[警告] 本次跳过了 sing-box SHA-256 校验（EASY_VPN_SKIP_SINGBOX_VERIFY=1）"
        return 0
    fi

    if checksum=$(fetch_release_asset_digest "$version" "$asset"); then
        printf '%s\n' "$checksum"
        return 0
    fi

    if fetch_checksums_file "$version" "$checksum_file"; then
        checksum=$(extract_singbox_checksum "$checksum_file" "$asset")
        if [[ "$checksum" =~ ^[A-Fa-f0-9]{64}$ ]]; then
            printf '%s\n' "$checksum"
            return 0
        fi
    fi

    echo -e "${RED}[错误]${PLAIN} 上游 v${version} 未提供可用校验值（已尝试 GitHub Release API 的 digest 与 7 种校验文件名），拒绝安装未经校验的 sing-box。" >&2
    echo -e "${YELLOW}[提示]${PLAIN} 可到 https://github.com/SagerNet/sing-box/releases/tag/v${version} 人工核验对应 ${asset} 的 SHA-256。" >&2
    echo -e "${YELLOW}[提示]${PLAIN} 如确认需要应急跳过，可显式设置 EASY_VPN_SKIP_SINGBOX_VERIFY=1；默认不会跳过校验。" >&2
    return 1
}

install_singbox() {
    if resolve_singbox; then
        echo -e "${GREEN}[环境]${PLAIN} 检测到现有 sing-box，将复用当前程序：${SINGBOX_BIN}"
    else
        local version arch asset_url asset checksum tmp
        case "$(uname -m)" in
            x86_64) arch=amd64 ;;
            aarch64) arch=arm64 ;;
            *) echo -e "${RED}[错误]${PLAIN} 不支持的 CPU 架构。"; return 1 ;;
        esac
        version="${SINGBOX_VERSION:-}"
        [[ -n "$version" ]] || version=$(latest_singbox_version)
        asset="sing-box-${version}-linux-${arch}.tar.gz"
        asset_url="https://github.com/SagerNet/sing-box/releases/download/v${version}/${asset}"
        tmp=$(make_temp_dir singbox-install 256) || { echo -e "${RED}[错误]${PLAIN} 无法创建 sing-box 下载临时目录，请检查安装目录磁盘空间和权限。" >&2; return 1; }

        echo -e "${BLUE}[环境]${PLAIN} 下载 sing-box v${version} 并校验 SHA-256..."
        if ! download_https "$asset_url" "${tmp}/${asset}"; then
            rm -rf "$tmp"
            return 1
        fi
        if checksum=$(resolve_singbox_checksum "$version" "$asset" "${tmp}/checksums.txt"); then
            if [[ -n "$checksum" ]]; then
                if ! echo "${checksum}  ${tmp}/${asset}" | sha256sum -c - >/dev/null; then
                    rm -rf "$tmp"
                    echo -e "${RED}[错误]${PLAIN} sing-box SHA-256 校验失败，已拒绝安装。"
                    return 1
                fi
            else
                echo -e "${YELLOW}[警告]${PLAIN} 本次未执行 sing-box SHA-256 校验。"
            fi
        else
            rm -rf "$tmp"
            return 1
        fi

        if ! mkdir -p "${EASY_VPN_ROOT}/bin"; then
            rm -rf "$tmp"
            echo -e "${RED}[错误]${PLAIN} 无法创建本地二进制目录。"
            return 1
        fi
        # The installer uses umask 077 to protect secrets. The program directory
        # and binary directory are not secret and must remain traversable/executable
        # by systemd's unprivileged easy-vpn account.
        chmod 0755 "${EASY_VPN_ROOT}" "${EASY_VPN_ROOT}/bin" || {
            rm -rf "$tmp"
            echo -e "${RED}[错误]${PLAIN} 无法设置 sing-box 安装路径权限。"
            return 1
        }
        if ! tar -xzf "${tmp}/${asset}" -C "$tmp"; then
            rm -rf "$tmp"
            echo -e "${RED}[错误]${PLAIN} sing-box 压缩包解压失败。"
            return 1
        fi
        local extracted
        extracted=$(find "$tmp" -type f -name sing-box -perm -u=x | head -n1)
        if [[ -z "$extracted" ]]; then
            rm -rf "$tmp"
            echo -e "${RED}[错误]${PLAIN} 压缩包中没有找到 sing-box。"
            return 1
        fi
        if ! install -m 0755 "$extracted" "${EASY_VPN_ROOT}/bin/sing-box"; then
            rm -rf "$tmp"
            return 1
        fi
        mark_owned "${EASY_VPN_ROOT}/bin/sing-box"
        SINGBOX_BIN="${EASY_VPN_ROOT}/bin/sing-box"
        rm -rf "$tmp"
        log_action "[可撤销] 安装经 SHA-256 校验的 sing-box v${version}"
    fi

    "$SINGBOX_BIN" version >/dev/null 2>&1 || { echo -e "${RED}[错误]${PLAIN} sing-box 二进制无法运行。"; return 1; }
    ensure_service_user

    mkdir -p "$CONF_DIR"
    chown root:easy-vpn "$CONF_DIR"
    chmod 0750 "$CONF_DIR"

    if [[ -e "$SERVICE_FILE" ]] && ! is_owned "$SERVICE_FILE"; then
        echo -e "${RED}[错误]${PLAIN} ${SERVICE_FILE} 已存在但不是本工具创建的，拒绝覆盖。"
        return 1
    fi
    backup_file_once "$SERVICE_FILE" protocol_service_unit
    local service_hardening="${EASY_VPN_SERVICE_HARDENING:-on}"
    case "${service_hardening,,}" in
        off|0|false|no)
            cat > "$SERVICE_FILE" <<EOF2
[Unit]
Description=Easy VPN sing-box service
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=300
StartLimitBurst=30

[Service]
Type=simple
User=easy-vpn
Group=easy-vpn
WorkingDirectory=/var/lib/easy-vpn
ExecStart=${SINGBOX_BIN} run -c ${CONF_FILE}
Restart=on-failure
RestartSec=5s
LimitNOFILE=65535
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
EOF2
            ;;
        *)
            cat > "$SERVICE_FILE" <<EOF2
[Unit]
Description=Easy VPN sing-box service
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=300
StartLimitBurst=30

[Service]
Type=simple
User=easy-vpn
Group=easy-vpn
WorkingDirectory=/var/lib/easy-vpn
ExecStart=${SINGBOX_BIN} run -c ${CONF_FILE}
Restart=on-failure
RestartSec=5s
LimitNOFILE=65535
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ReadWritePaths=/var/lib/easy-vpn
ProtectHome=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectKernelLogs=true
ProtectControlGroups=true
RestrictNamespaces=true
RestrictSUIDSGID=true
LockPersonality=true
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6 AF_NETLINK
ReadOnlyPaths=/etc/easy-vpn/sing-box

[Install]
WantedBy=multi-user.target
EOF2
            ;;
    esac
    chmod 0644 "$SERVICE_FILE"
    mark_owned "$SERVICE_FILE"

systemctl daemon-reload
systemctl enable "$SERVICE_UNIT" >/dev/null
}

is_valid_ipv4_literal() {
    local value="${1:-}" a b c d
    [[ "$value" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
    a="${BASH_REMATCH[1]}"; b="${BASH_REMATCH[2]}"; c="${BASH_REMATCH[3]}"; d="${BASH_REMATCH[4]}"
    (( 10#$a <= 255 && 10#$b <= 255 && 10#$c <= 255 && 10#$d <= 255 ))
}

is_valid_ipv6_literal() {
    local value="${1:-}"
    [[ "$value" == *:* && "$value" =~ ^[0-9A-Fa-f:.]+$ && "$value" != *:::* ]] || return 1
    # Let iproute2's parser perform the full syntax check when available.
    if command_exists python3; then
        python3 - "$value" <<'PYIP' >/dev/null 2>&1
import ipaddress, sys
ipaddress.IPv6Address(sys.argv[1])
PYIP
    else
        [[ $(grep -o ':' <<< "$value" | wc -l) -ge 2 ]]
    fi
}

get_sys_ip() {
    local family url address
    local -a providers4=(https://api.ipify.org https://ipv4.icanhazip.com https://ifconfig.me/ip)
    local -a providers6=(https://api6.ipify.org https://ipv6.icanhazip.com https://ifconfig.co/ip)
    for url in "${providers4[@]}"; do
        address=$(curl -4 --fail --silent --show-error --location --proto '=https' --tlsv1.2 --connect-timeout 3 --max-time 5 "$url" 2>/dev/null | tr -d '[:space:]' || true)
        if is_valid_ipv4_literal "$address"; then printf '%s\n' "$address"; return 0; fi
    done
    for url in "${providers6[@]}"; do
        address=$(curl -6 --fail --silent --show-error --location --proto '=https' --tlsv1.2 --connect-timeout 3 --max-time 5 "$url" 2>/dev/null | tr -d '[:space:]' || true)
        if is_valid_ipv6_literal "$address"; then printf '[%s]\n' "$address"; return 0; fi
    done
    return 1
}

# Store/display the address without URI brackets; add brackets only when placing
# an IPv6 literal into a URI authority (host:port).
normalize_server_address() {
    local host="${1:-}"
    if [[ "$host" == \[*\] ]]; then
        host="${host#[}"
        host="${host%]}"
    fi
    printf '%s\n' "$host"
}

format_uri_host() {
    local host
    host=$(normalize_server_address "${1:-}")
    if [[ "$host" == *:* ]]; then
        printf '[%s]\n' "$host"
    else
        printf '%s\n' "$host"
    fi
}

get_random_protocol_port() {
    random_free_port "$1"
}

validate_user_port() {
    local port="$1"
    validate_port "$port"
}

validate_sni_hostname() {
    local host="${1:-}" label
    local -a labels=()
    [[ ${#host} -ge 3 && ${#host} -le 253 ]] || return 1
    [[ "$host" =~ ^[A-Za-z0-9.-]+$ && "$host" != .* && "$host" != *. && "$host" != *..* ]] || return 1
    [[ "$host" == *.* ]] || return 1
    IFS='.' read -r -a labels <<< "$host"
    for label in "${labels[@]}"; do
        [[ ${#label} -le 63 && "$label" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]] || return 1
    done
}

# Fall back to an IPv4 wildcard when the system has disabled or lacks IPv6.
# Optional file arguments make the detection testable without changing sysctls.
protocol_listen_address() {
    local disable_file="${1:-/proc/sys/net/ipv6/conf/all/disable_ipv6}"
    local ipv6_proc_file="${2:-/proc/net/if_inet6}" disabled=""
    if [[ -r "$disable_file" ]]; then
        IFS= read -r disabled < "$disable_file" || true
        [[ "$disabled" == 1 ]] && { printf '0.0.0.0\n'; return 0; }
    fi
    if [[ ! -d /proc/sys/net/ipv6 || ! -e "$ipv6_proc_file" ]]; then
        printf '0.0.0.0\n'
    else
        printf '::\n'
    fi
}

get_best_sni() {
    local candidates=(gateway.icloud.com itunes.apple.com addons.mozilla.org swdist.apple.com www.microsoft.com images.unsplash.com)
    local tmp domain elapsed best="" result_file
    tmp=$(make_temp_dir sni) || { echo "addons.mozilla.org"; return 0; }
    for domain in "${candidates[@]}"; do
        (
            # Reality relies on TLS 1.3. Test the TLS handshake itself rather than
            # selecting a host based only on TCP connect latency. Each worker writes
            # a private result file to avoid concurrent append/parse races.
            elapsed=$(curl --tlsv1.3 -o /dev/null -sS -w '%{time_appconnect}' --connect-timeout 2 --max-time 4 "https://${domain}" 2>/dev/null || true)
            [[ "$elapsed" =~ ^[0-9]+([.][0-9]+)?$ && "$elapsed" != 0 && "$elapsed" != 0.000000 ]] || exit 0
            printf '%s %s\n' "$elapsed" "$domain" > "${tmp}/${domain}.result"
        ) &
    done
    wait
    if compgen -G "${tmp}/*.result" >/dev/null; then
        best=$(cat "${tmp}"/*.result | sort -n | head -n1 | awk '{print $2}')
    fi
    rm -rf -- "$tmp"
    if [[ -n "$best" ]]; then
        printf '%s\n' "$best"
    else
        echo -e "${YELLOW}[提示]${PLAIN} 所有候选站点均未通过 TLS 1.3 握手测试，回退到 addons.mozilla.org；请根据客户端网络情况确认可达性。" >&2
        log_action "[提示] 所有候选站点均未通过 TLS 1.3 握手测试，回退到 addons.mozilla.org"
        printf 'addons.mozilla.org\n'
    fi
}

protocol_fragment_file() {
    local name="$1"
    case "$name" in
        vless) printf '%s/vless.json' "$CONF_DIR" ;;
        hy2) printf '%s/hy2.json' "$CONF_DIR" ;;
        tuic) printf '%s/tuic.json' "$CONF_DIR" ;;
        *) return 1 ;;
    esac
}

protocol_node_info_file() {
    local name="$1"
    case "$name" in
        vless) printf '%s/node_info_vless.txt' "$PROTOCOL_NODE_INFO_DIR" ;;
        hy2) printf '%s/node_info_hy2.txt' "$PROTOCOL_NODE_INFO_DIR" ;;
        tuic) printf '%s/node_info_tuic.txt' "$PROTOCOL_NODE_INFO_DIR" ;;
        *) return 1 ;;
    esac
}

protocol_transport() {
    case "$1" in
        vless) printf 'tcp' ;;
        hy2|tuic) printf 'udp' ;;
        *) return 1 ;;
    esac
}

protocol_port_state_key() {
    printf 'protocol_%s_port' "$1"
}

protocol_fragment_names() {
    printf '%s\n' vless hy2 tuic
}

write_protocol_fragment() {
    local name="$1" json="$2" file tmp
    file=$(protocol_fragment_file "$name") || return 1
    mkdir -p "$CONF_DIR"
    tmp=$(mktemp "${CONF_DIR}/.${name}.json.XXXXXX") || { echo -e "${RED}[错误]${PLAIN} 无法为 ${name} 创建临时配置文件。" >&2; return 1; }
    if ! printf '%s\n' "$json" | jq -e 'type == "object" and (.type | type == "string") and (.tag | type == "string")' >/dev/null; then
        rm -f "$tmp"
        echo -e "${RED}[错误]${PLAIN} ${name} 协议片段不是合法的 inbound JSON，拒绝写入。"
        return 1
    fi
    printf '%s\n' "$json" > "$tmp"
    chmod 0640 "$tmp"
    chown root:easy-vpn "$tmp"
    mv -f "$tmp" "$file"
    mark_owned "$file"
}

regenerate_singbox_config() {
    local files=() name file tmp
    for name in $(protocol_fragment_names); do
        file=$(protocol_fragment_file "$name") || return 1
        [[ -f "$file" ]] || continue
        files+=("$file")
    done

    if (( ${#files[@]} == 0 )); then
        if systemctl is-active --quiet "$SERVICE_UNIT" 2>/dev/null; then
            systemctl stop "$SERVICE_UNIT" || return 1
        fi
        if systemctl is-enabled --quiet "$SERVICE_UNIT" 2>/dev/null; then
            systemctl disable "$SERVICE_UNIT" >/dev/null || return 1
        fi
        if [[ -e "$CONF_FILE" ]]; then
            rm -f "$CONF_FILE"
        fi
        return 0
    fi

    for file in "${files[@]}"; do
        jq -e 'type == "object" and (.type | type == "string") and (.tag | type == "string")' "$file" >/dev/null || {
            echo -e "${RED}[错误]${PLAIN} 协议片段 JSON 非法：${file}；原 config.json 保持不变。"
            return 1
        }
    done

    tmp=$(mktemp "${CONF_DIR}/.config.json.XXXXXX") || { echo -e "${RED}[错误]${PLAIN} 无法创建 sing-box 临时配置文件。" >&2; return 1; }
    if ! jq -s '
        {
            log: {level: "warn", timestamp: true},
            inbounds: .,
            outbounds: [{type: "direct", tag: "direct"}]
        }
        | if ([.inbounds[].tag] | length) == ([.inbounds[].tag] | unique | length) then . else error("duplicate inbound tag") end
    ' "${files[@]}" > "$tmp"; then
        rm -f "$tmp"
        echo -e "${RED}[错误]${PLAIN} 合并协议片段失败，原 config.json 保持不变。"
        return 1
    fi

    if ! jq -e '.inbounds | type == "array" and length > 0' "$tmp" >/dev/null; then
        rm -f "$tmp"
        echo -e "${RED}[错误]${PLAIN} 合并后的 sing-box 配置缺少 inbound，原 config.json 保持不变。"
        return 1
    fi
    chown root:easy-vpn "$tmp"
    chmod 0640 "$tmp"
    mv -f "$tmp" "$CONF_FILE"
}

remove_protocol_fragment() {
    local name="$1" file rollback_dir
    file=$(protocol_fragment_file "$name") || return 1
    [[ -f "$file" ]] || return 1
    rollback_dir=$(make_temp_dir "protocol-${name}-fragment-remove") || { echo -e "${RED}[错误]${PLAIN} 无法创建 ${name} 卸载回滚目录，未删除协议文件。" >&2; return 1; }
    cp -a "$file" "${rollback_dir}/fragment"
    rm -f "$file"
    unmark_owned "$file"
    if ! regenerate_singbox_config; then
        cp -a "${rollback_dir}/fragment" "$file"
        mark_owned "$file"
        regenerate_singbox_config >/dev/null 2>&1 || true
        rm -rf "$rollback_dir"
        return 1
    fi
    rm -rf "$rollback_dir"
}

restore_protocol_fragment_transaction() {
    local name="$1" rollback_dir="$2" had_fragment="$3" file
    file=$(protocol_fragment_file "$name") || return 1
    if [[ "$had_fragment" == "1" ]]; then
        cp -a "${rollback_dir}/fragment" "$file"
        mark_owned "$file"
    else
        rm -f "$file"
        unmark_owned "$file"
    fi
    regenerate_singbox_config
}

validate_singbox_config() {
    resolve_singbox || return 1
    "$SINGBOX_BIN" check -c "$CONF_FILE"
}

ensure_conf_permissions() {
    mkdir -p "$CONF_DIR"
    chown root:easy-vpn "$CONF_DIR"
    chmod 0750 "$CONF_DIR"
    [[ -f "$CONF_FILE" ]] && { chown root:easy-vpn "$CONF_FILE"; chmod 0640 "$CONF_FILE"; }
    [[ -f "$NODE_INFO_FILE" ]] && { chown root:root "$NODE_INFO_FILE"; chmod 0600 "$NODE_INFO_FILE"; }
    local name path
    for name in $(protocol_fragment_names); do
        path=$(protocol_fragment_file "$name") || continue
        [[ -f "$path" ]] && { chown root:easy-vpn "$path"; chmod 0640 "$path"; }
        path=$(protocol_node_info_file "$name") || continue
        [[ -f "$path" ]] && { chown root:root "$path"; chmod 0600 "$path"; }
    done
    # Hysteria 2 / TUIC 证书和私钥由生成步骤单独设置权限；这里不覆盖其专用权限。
    return 0
}

prepare_protocol_state() {
    ensure_conf_permissions
    backup_file_once "$CONF_FILE" protocol_config
    backup_file_once "$NODE_INFO_FILE" protocol_node_info
}

write_protocol_node_info() {
    local name="$1" content="$2" file
    file=$(protocol_node_info_file "$name") || return 1
    umask 077
    printf '%s\n' "$content" > "$file"
    chown root:root "$file"
    chmod 0600 "$file"
    mark_owned "$file"
}

protocol_listener_is_up() {
    local name="$1" port transport main_pid ss_output
    # A matching port owned by nginx/caddy or an old process is not proof that
    # sing-box is healthy. Tie the socket check to this unit's MainPID.
    if [[ -f "$CONF_FILE" ]]; then
        port=$(jq -r --arg tag "${name}-in" '.inbounds[] | select(.tag == $tag) | .listen_port' "$CONF_FILE" 2>/dev/null | head -n1)
    fi
    [[ -n "${port:-}" ]] || port=$(state_get "$(protocol_port_state_key "$name")" 2>/dev/null || true)
    [[ "$port" =~ ^[0-9]{1,5}$ ]] || return 1
    (( 10#$port >= 1 && 10#$port <= 65535 )) || return 1
    transport=$(protocol_transport "$name") || return 1
    command_exists ss || return 1
    main_pid=$(systemctl show -p MainPID "$SERVICE_UNIT" 2>/dev/null | sed -n 's/^MainPID=//p' | head -n1)
    [[ "$main_pid" =~ ^[1-9][0-9]*$ ]] || return 1
    ss_output=$(ss -H -lntup 2>/dev/null) || return 1
    awk -v port="$port" -v proto="$transport" -v pid="$main_pid" '
        $1 == proto {
            local_port = $5
            if (local_port ~ (":" port "$")) {
                owner_pattern = "pid=" pid "([,)]|$)"
                if ($0 ~ owner_pattern) found = 1
            }
        }
        END { exit found ? 0 : 1 }
    ' <<< "$ss_output"
}

protocol_status_text() {
    local name="$1"
    if ! state_exists "protocol_${name}"; then
        printf '未部署'
    elif ! systemctl is-active --quiet "$SERVICE_UNIT" 2>/dev/null; then
        printf '已部署/服务未运行'
    elif protocol_listener_is_up "$name"; then
        printf '运行中'
    else
        printf '已部署/服务活动但未检测到监听'
    fi
}

remove_protocol_resources() {
    local name="$1" cert_file key_file node_file port transport
    node_file=$(protocol_node_info_file "$name") || return 1
    port=$(state_get "$(protocol_port_state_key "$name")" 2>/dev/null || true)
    transport=$(protocol_transport "$name") || return 1

    case "$name" in
        hy2) cert_file="${CONF_DIR}/hy2_cert.pem"; key_file="${CONF_DIR}/hy2_key.pem" ;;
        tuic) cert_file="${CONF_DIR}/tuic_cert.pem"; key_file="${CONF_DIR}/tuic_key.pem" ;;
        vless) cert_file=""; key_file="" ;;
        *) return 1 ;;
    esac

    remove_port_hopping "$name" || true
    if [[ -n "$port" ]] && ! firewall_remove_owned_rules "$port" "$transport"; then
        echo -e "${YELLOW}[警告]${PLAIN} ${name} 的 ${port}/${transport} 防火墙规则未能删除，已保留记录以便后续重试。"
    fi
    if [[ -n "$cert_file" && -f "$cert_file" ]] && is_owned "$cert_file"; then
        rm -f "$cert_file"
        unmark_owned "$cert_file"
    fi
    if [[ -n "$key_file" && -f "$key_file" ]] && is_owned "$key_file"; then
        rm -f "$key_file"
        unmark_owned "$key_file"
    fi
    if is_owned "$node_file"; then
        rm -f "$node_file"
        unmark_owned "$node_file"
    fi
    state_unset "protocol_${name}"
    state_unset "$(protocol_port_state_key "$name")"
}

service_was_running() {
    systemctl is-active --quiet "$SERVICE_UNIT" 2>/dev/null
}

show_singbox_start_failure() {
    echo -e "${RED}[错误]${PLAIN} sing-box 服务启动失败，下面是最近 20 条真实日志："
    journalctl -u "$SERVICE_UNIT" -n 20 --no-pager -l 2>/dev/null | sed 's/^/    /' || true
    log_action "[错误] ${SERVICE_UNIT} 启动失败；请执行 journalctl -u ${SERVICE_UNIT} -n 50 --no-pager -l 查看详情"
}

configured_inbounds_are_listening() {
    local type port proto found=0
    [[ -f "$CONF_FILE" ]] || return 1
    command_exists jq && command_exists ss || return 1
    while IFS=$'\t' read -r type port; do
        [[ -n "$type" && "$port" =~ ^[0-9]+$ ]] || continue
        case "$type" in
            vless) proto=vless ;;
            hysteria2) proto=hy2 ;;
            tuic) proto=tuic ;;
            *) echo "unsupported inbound type while checking service health: $type" >&2; return 1 ;;
        esac
        found=1
        protocol_listener_is_up "$proto" || return 1
    done < <(jq -r '.inbounds[]? | [.type,(.listen_port|tostring)] | @tsv' "$CONF_FILE" 2>/dev/null)
    (( found == 1 ))
}

restart_service_and_verify() {
    systemctl daemon-reload
    if ! systemctl restart "$SERVICE_UNIT"; then
        show_singbox_start_failure
        systemctl stop "$SERVICE_UNIT" >/dev/null 2>&1 || true
        systemctl reset-failed "$SERVICE_UNIT" >/dev/null 2>&1 || true
        return 1
    fi

    local attempt
    for ((attempt = 1; attempt <= 20; attempt++)); do
        if systemctl is-active --quiet "$SERVICE_UNIT" && configured_inbounds_are_listening; then
            return 0
        fi
        if systemctl is-failed --quiet "$SERVICE_UNIT"; then
            show_singbox_start_failure
            systemctl stop "$SERVICE_UNIT" >/dev/null 2>&1 || true
            systemctl reset-failed "$SERVICE_UNIT" >/dev/null 2>&1 || true
            return 1
        fi
        sleep 0.5
    done

    show_singbox_start_failure
    systemctl stop "$SERVICE_UNIT" >/dev/null 2>&1 || true
    systemctl reset-failed "$SERVICE_UNIT" >/dev/null 2>&1 || true
    return 1
}

write_node_info() {
    local content="$1"
    umask 077
    printf '%s\n' "$content" > "$NODE_INFO_FILE"
    chown root:root "$NODE_INFO_FILE"
    chmod 0600 "$NODE_INFO_FILE"
}

firewall_note() {
    local port="$1" proto="$2"
    local backend
    backend=$(firewall_backend)
    if [[ "$backend" == "none" ]]; then
        echo -e "${YELLOW}[提示]${PLAIN} 未检测到活动主机防火墙；请检查云安全组/边界防火墙。"
    else
        firewall_allow "$port" "$proto" || echo -e "${YELLOW}[提示]${PLAIN} 防火墙放行规则添加失败，请手工检查。"
    fi
}


protocol_hop_state_key() {
    printf '%s_hop_ports' "$1"
}

protocol_hop_backend_state_key() {
    printf '%s_hop_backend' "$1"
}

protocol_hop_listen_state_key() {
    printf '%s_hop_listen_port' "$1"
}

validate_hop_range() {
    local range="$1" start end span
    [[ "$range" =~ ^([0-9]{1,5})-([0-9]{1,5})$ ]] || return 1
    start="${BASH_REMATCH[1]}"; end="${BASH_REMATCH[2]}"
    (( start >= 1024 && end <= 65535 && start < end )) || return 1
    span=$((end-start))
    (( span <= 200 ))
}

hop_range_conflicts() {
    local start="$1" end="$2" other_name other_port other_range other_start other_end occupied_ports
    for other_name in $(protocol_fragment_names); do
        [[ -f "$(protocol_fragment_file "$other_name")" ]] || continue
        other_port=$(state_get "$(protocol_port_state_key "$other_name")" 2>/dev/null || true)
        if [[ "$other_port" =~ ^[0-9]+$ ]] && (( other_port >= start && other_port <= end )); then
            return 0
        fi
        other_range=$(state_get "$(protocol_hop_state_key "$other_name")" 2>/dev/null || true)
        if [[ "$other_range" =~ ^([0-9]+)-([0-9]+)$ ]]; then
            other_start="${BASH_REMATCH[1]}"
            other_end="${BASH_REMATCH[2]}"
            if (( start <= other_end && end >= other_start )); then
                return 0
            fi
        fi
    done

    if command_exists ss; then
        occupied_ports=$(ss -H -lun 2>/dev/null | awk -v start="$start" -v end="$end" '
            {
                for (i = 1; i <= NF; i++) {
                    field=$i
                    if (field ~ /:[0-9]+$/) {
                        port=field
                        sub(/^.*:/, "", port)
                        if (port ~ /^[0-9]+$/ && port >= start && port <= end) {
                            print port
                        }
                        break
                    }
                }
            }
        ')
        [[ -z "$occupied_ports" ]] || return 0
    else
        for ((port=start; port<=end; port++)); do
            port_in_use "$port" udp && return 0
        done
    fi
    return 1
}

prompt_port_hopping() {
    local choice range start end blank_attempts=0
    PORT_HOP_RANGE=""
    PORT_HOP_ENABLED=0
    [[ "${1:-0}" == "1" ]] || return 0
    echo -e "${YELLOW}[说明]${PLAIN} UFW/firewalld 将按整个 UDP 端口段添加一条放行规则；NAT 跳转规则由本工具单独管理。关闭时会撤销本工具创建的规则。"
    read -rp "是否启用 UDP 端口跳跃（可缓解晚高峰 UDP 限速）？[Y/n]: " choice || { echo -e "${YELLOW}[取消]${PLAIN} 未读取到端口跳跃选择。"; return 1; }
    [[ "$choice" =~ ^[Nn]$ ]] && return 0
    while true; do
        read -rp "输入端口范围（例如 20000-20100，跨度 ≤ 200）：" range
        if [[ -z "$range" ]]; then
            ((blank_attempts += 1))
            echo -e "${YELLOW}[提示]${PLAIN} 必须输入端口范围。"
            if (( blank_attempts >= 3 )); then
                echo -e "${YELLOW}[提示]${PLAIN} 连续 3 次未输入端口范围，已取消端口跳跃并继续部署。"
                return 0
            fi
            continue
        fi
        if ! validate_hop_range "$range"; then
            echo -e "${RED}[错误]${PLAIN} 范围必须为 1024-65535、起 < 止、跨度 ≤ 200。"
            continue
        fi
        start="${range%-*}"; end="${range#*-}"
        echo -e "${YELLOW}[提醒]${PLAIN} 云平台安全组需放行整段 UDP ${start}-${end}，本工具只能管理本机防火墙。"
        if hop_range_conflicts "$start" "$end"; then
            echo -e "${RED}[错误]${PLAIN} 端口范围与现有监听/已部署协议存在冲突，请换一段范围。"
            continue
        fi
        PORT_HOP_RANGE="$range"
        PORT_HOP_ENABLED=1
        return 0
    done
}

write_hop_persistence_file() {
    local name="$1" backend="$2" range="$3" listen_port="$4" ipv4_enabled="${5:-1}" ipv6_enabled="${6:-0}" dir file tmp_file
    [[ "$name" =~ ^(hy2|hysteria2)$ ]] || return 1
    validate_hop_range "$range" || return 1
    validate_user_port "$listen_port" || return 1
    dir="${EASY_VPN_ETC}/port-hop"
    [[ ! -L "$dir" && ( ! -e "$dir" || -d "$dir" ) ]] || {
        echo -e "${RED}[错误]${PLAIN} 端口跳跃状态目录不是安全的普通目录：${dir}" >&2
        return 1
    }
    mkdir -p "$dir" || return 1
    case "$backend" in
        nft) file="${dir}/${name}.nft" ;;
        iptables) file="${dir}/${name}.iptables" ;;
        *) return 1 ;;
    esac
    if [[ -e "$file" || -L "$file" ]]; then
        echo -e "${YELLOW}[安全保留]${PLAIN} 端口跳跃规则文件已存在：${file}；拒绝直接覆盖，避免覆盖尚未清理的旧规则。" >&2
        return 1
    fi
    # Write to a private temporary file, then link it into place atomically. `ln`
    # fails rather than overwriting a file that appeared after the initial check.
    tmp_file=$(mktemp "${dir}/.${name}.${backend}.XXXXXX") || return 1
    if [[ "$backend" == nft ]]; then
        if ! cat > "$tmp_file" <<EOF
 table inet easy_vpn_hop_${name} {
  chain prerouting {
    type nat hook prerouting priority dstnat; policy accept;
    # inet NAT supports IPv4 and IPv6 (Linux 5.2+); redirect targets this host's local port.
    udp dport ${range} redirect to :${listen_port}
  }
}
EOF
        then
            rm -f -- "$tmp_file"
            return 1
        fi
    else
        # Data-only format: v2 records the enabled address families so a
        # dual-stack host can restore IPv4 and IPv6 rules independently.
        if (( $# >= 6 )); then
            [[ "$ipv4_enabled" =~ ^[01]$ && "$ipv6_enabled" =~ ^[01]$ ]] || { rm -f -- "$tmp_file"; return 1; }
            (( ipv4_enabled || ipv6_enabled )) || { rm -f -- "$tmp_file"; return 1; }
            if ! printf 'format=easy-vpn-port-hop-v2\nname=%s\nrange=%s\nlisten_port=%s\nipv4=%s\nipv6=%s\n' \
                "$name" "$range" "$listen_port" "$ipv4_enabled" "$ipv6_enabled" > "$tmp_file"; then
                rm -f -- "$tmp_file"
                return 1
            fi
        else
            # Backward-compatible v1 data format remains used by migration/tests.
            if ! printf 'format=easy-vpn-port-hop-v1\nname=%s\nrange=%s\nlisten_port=%s\n' \
                "$name" "$range" "$listen_port" > "$tmp_file"; then
                rm -f -- "$tmp_file"
                return 1
            fi
        fi
    fi
    chmod 600 "$tmp_file" || { rm -f -- "$tmp_file"; return 1; }
    if ! ln -- "$tmp_file" "$file"; then
        rm -f -- "$tmp_file"
        echo -e "${YELLOW}[安全保留]${PLAIN} 端口跳跃文件在写入期间出现冲突：${file}；拒绝覆盖。" >&2
        return 1
    fi
    rm -f -- "$tmp_file"
    if ! mark_owned "$file"; then
        rm -f -- "$file"
        unmark_owned "$file"
        return 1
    fi
    printf '%s\n' "$file"
}

# Install one shared, idempotent restore unit for both nftables and iptables.
# It is a weak sing-box dependency: a broken optional hop restore must not block
# VLESS/Reality, TUIC, or a single-port Hysteria listener from starting.
ensure_port_hop_restore_service() {
    local helper unit dropin_dir dropin nft_bin iptables_bin ip6tables_bin path tmp
    helper="${EASY_VPN_ROOT}/bin/easy-vpn-port-hop-restore"
    unit="${SYSTEMD_DIR}/easy-vpn-port-hop.service"
    dropin_dir="${SYSTEMD_DIR}/${SERVICE_UNIT}.d"
    dropin="${dropin_dir}/30-easy-vpn-port-hop.conf"
    nft_bin=$(command -v nft || true)
    iptables_bin=$(command -v iptables || true)
    ip6tables_bin=$(command -v ip6tables || true)
    command_exists systemctl || return 1

    if [[ -x "$helper" && -f "$unit" && -f "$dropin" && ! -L "$helper" && ! -L "$unit" && ! -L "$dropin" ]] &&
       is_owned "$helper" && is_owned "$unit" && is_owned "$dropin" &&
       grep -Fq "ExecStart=${helper} apply-all" "$unit" &&
       grep -Fq 'apply_iptables_file()' "$helper" &&
       grep -Fq 'apply_iptables_family()' "$helper" &&
       grep -Fq 'EASY_VPN_IP6TABLES_BIN' "$unit" &&
       grep -Fq 'Wants=easy-vpn-port-hop.service' "$dropin" &&
       ! grep -Fq 'Requires=easy-vpn-port-hop.service' "$dropin"; then
        systemctl is-enabled --quiet easy-vpn-port-hop.service 2>/dev/null || systemctl enable easy-vpn-port-hop.service >/dev/null || return 1
        return 0
    fi

    for path in "$helper" "$unit" "$dropin"; do
        if [[ -e "$path" || -L "$path" ]]; then
            if ! is_owned "$path" || [[ ! -f "$path" || -L "$path" ]]; then
                echo -e "${RED}[错误]${PLAIN} 端口跳跃持久化文件已存在且不属于 Easy VPN：${path}；拒绝覆盖。"
                return 1
            fi
        fi
    done
    [[ ! -L "${EASY_VPN_ROOT}/bin" && ( ! -e "${EASY_VPN_ROOT}/bin" || -d "${EASY_VPN_ROOT}/bin" ) ]] || return 1
    [[ ! -L "$SYSTEMD_DIR" && ( ! -e "$SYSTEMD_DIR" || -d "$SYSTEMD_DIR" ) ]] || return 1
    [[ ! -L "$dropin_dir" && ( ! -e "$dropin_dir" || -d "$dropin_dir" ) ]] || return 1
    mkdir -p "${EASY_VPN_ROOT}/bin" "$SYSTEMD_DIR" "$dropin_dir" || return 1

    tmp=$(mktemp "${EASY_VPN_ROOT}/bin/.port-hop-restore.XXXXXX") || return 1
    cat > "$tmp" <<'EOF_HOP_RESTORE'
#!/usr/bin/env bash
set -Eeuo pipefail
EASY_VPN_ETC="${EASY_VPN_ETC:-/etc/easy-vpn}"
RULE_DIR="${EASY_VPN_ETC}/port-hop"
NFT_BIN="${EASY_VPN_NFT_BIN:-$(command -v nft || true)}"
IPTABLES_BIN="${EASY_VPN_IPTABLES_BIN:-$(command -v iptables || true)}"
IP6TABLES_BIN="${EASY_VPN_IP6TABLES_BIN:-$(command -v ip6tables || true)}"

valid_range() {
    local value="$1" start end
    [[ "$value" =~ ^([0-9]{1,5})-([0-9]{1,5})$ ]] || return 1
    start="${BASH_REMATCH[1]}"; end="${BASH_REMATCH[2]}"
    ((10#$start >= 1024 && 10#$end <= 65535 && 10#$start < 10#$end && 10#$end - 10#$start <= 200))
}
valid_listen_port() { [[ "$1" =~ ^[0-9]{1,5}$ ]] && { [[ "$1" == 80 || "$1" == 443 ]] || ((10#$1 >= 1024 && 10#$1 <= 65535)); }; }

nft_rule_identity() {
    local file="$1" base name line family table expected_easy expected_legacy
    local -a declarations=()
    [[ -f "$file" && ! -L "$file" && "$(dirname -- "$file")" == "$RULE_DIR" ]] || return 1
    base="$(basename -- "$file")"; [[ "$base" =~ ^([a-z][a-z0-9_-]{0,31})\.nft$ ]] || return 1
    name="${BASH_REMATCH[1]}"
    mapfile -t declarations < <(sed -nE 's/^[[:space:]]*table[[:space:]]+(ip|inet)[[:space:]]+([a-zA-Z0-9_]+)[[:space:]]*\{[[:space:]]*$/\1|\2/p' "$file")
    ((${#declarations[@]} == 1)) || return 1
    IFS='|' read -r family table <<< "${declarations[0]}"
    expected_easy="easy_vpn_hop_${name}"; expected_legacy="vps_tool_hop_${name}"
    [[ "$table" == "$expected_easy" || "$table" == "$expected_legacy" ]] || return 1
    grep -Eq '^[[:space:]]*udp[[:space:]]+dport[[:space:]]+[0-9]{1,5}-[0-9]{1,5}[[:space:]]+redirect[[:space:]]+to[[:space:]]*:?[0-9]{1,5}[[:space:]]*$' "$file" || return 1
    printf '%s|%s\n' "$family" "$table"
}

apply_nft_file() {
    local file="$1" identity family table name check_table tmpdir check_file backup_file had_old=0
    identity=$(nft_rule_identity "$file") || { echo "refusing invalid Easy VPN nft rule file: $file" >&2; return 1; }
    IFS='|' read -r family table <<< "$identity"
    name="${table#easy_vpn_hop_}"; name="${name#vps_tool_hop_}"
    [[ -n "$NFT_BIN" && -x "$NFT_BIN" ]] || { echo "nft executable not found" >&2; return 1; }
    tmpdir=$(mktemp -d) || return 1
    check_table="easy_vpn_validate_${name}_$$"
    check_file="${tmpdir}/check.nft"; backup_file="${tmpdir}/previous.nft"
    sed -E "s/(table[[:space:]]+)${family}([[:space:]]+)${table}([[:space:]]*\{)/\1${family}\2${check_table}\3/" "$file" > "$check_file"
    if ! "$NFT_BIN" -c -f "$check_file"; then
        rm -rf -- "$tmpdir"; echo "nft syntax/kernel NAT validation failed for $file" >&2; return 1
    fi
    if "$NFT_BIN" list table "$family" "$table" > "$backup_file" 2>/dev/null; then
        had_old=1
        if ! "$NFT_BIN" delete table "$family" "$table"; then
            rm -rf -- "$tmpdir"; echo "could not replace existing nft table $table" >&2; return 1
        fi
    fi
    if "$NFT_BIN" -f "$file"; then rm -rf -- "$tmpdir"; return 0; fi
    if (( had_old )) && ! "$NFT_BIN" -f "$backup_file"; then
        echo "CRITICAL: failed to restore previous nft table $family $table from $backup_file" >&2
    fi
    rm -rf -- "$tmpdir"
    return 1
}

iptables_rule_identity() {
    local file="$1" base name line1 line2 line3 chain start end listen_port range ipv4_enabled=1 ipv6_enabled=0
    local -a lines=()
    [[ -f "$file" && ! -L "$file" && "$(dirname -- "$file")" == "$RULE_DIR" ]] || return 1
    base="$(basename -- "$file")"; [[ "$base" =~ ^(hy2|hysteria2)\.iptables$ ]] || return 1
    mapfile -t lines < "$file"
    if ((${#lines[@]} == 6)) && [[ "${lines[0]}" == format=easy-vpn-port-hop-v2 ]]; then
        local count_name count_range count_port count_ipv4 count_ipv6
        count_name=$(grep -c '^name=' "$file" || true); count_range=$(grep -c '^range=' "$file" || true); count_port=$(grep -c '^listen_port=' "$file" || true)
        count_ipv4=$(grep -c '^ipv4=' "$file" || true); count_ipv6=$(grep -c '^ipv6=' "$file" || true)
        [[ "$count_name" == 1 && "$count_range" == 1 && "$count_port" == 1 && "$count_ipv4" == 1 && "$count_ipv6" == 1 ]] || return 1
        name="$(sed -n 's/^name=//p' "$file")"
        range="$(sed -n 's/^range=//p' "$file")"
        listen_port="$(sed -n 's/^listen_port=//p' "$file")"
        ipv4_enabled="$(sed -n 's/^ipv4=//p' "$file")"
        ipv6_enabled="$(sed -n 's/^ipv6=//p' "$file")"
        [[ "$ipv4_enabled" =~ ^[01]$ && "$ipv6_enabled" =~ ^[01]$ ]] && (( ipv4_enabled || ipv6_enabled )) || return 1
        [[ "$base" == "${name}.iptables" ]] || return 1
    elif ((${#lines[@]} == 4)) && [[ "${lines[0]}" == format=easy-vpn-port-hop-v1 ]]; then
        local count_name count_range count_port
        count_name=$(grep -c '^name=' "$file" || true); count_range=$(grep -c '^range=' "$file" || true); count_port=$(grep -c '^listen_port=' "$file" || true)
        [[ "$count_name" == 1 && "$count_range" == 1 && "$count_port" == 1 ]] || return 1
        name="$(sed -n 's/^name=//p' "$file")"
        range="$(sed -n 's/^range=//p' "$file")"
        listen_port="$(sed -n 's/^listen_port=//p' "$file")"
        [[ "$base" == "${name}.iptables" ]] || return 1
    elif ((${#lines[@]} == 3)); then
        # Backward compatibility with 1.0.5 command-style files; parse strictly, never source/eval them.
        line1="${lines[0]}"; line2="${lines[1]}"; line3="${lines[2]}"
        [[ "$line1" =~ ^iptables\ -t\ nat\ -N\ EASY_VPN_HOP_([A-Z0-9_]+)$ ]] || return 1
        chain="${BASH_REMATCH[1]}"; name="${chain#EASY_VPN_HOP_}"; name="${name,,}"
        [[ "$base" == "${name}.iptables" ]] || return 1
        [[ "$line2" =~ ^iptables\ -t\ nat\ -A\ PREROUTING\ -p\ udp\ --dport\ ([0-9]{1,5}):([0-9]{1,5})\ -j\ ${chain}$ ]] || return 1
        start="${BASH_REMATCH[1]}"; end="${BASH_REMATCH[2]}"; range="${start}-${end}"
        [[ "$line3" =~ ^iptables\ -t\ nat\ -A\ ${chain}\ -p\ udp\ -j\ DNAT\ --to-destination\ :([0-9]{1,5})$ ]] || return 1
        listen_port="${BASH_REMATCH[1]}"
    else
        return 1
    fi
    [[ "$name" == hy2 || "$name" == hysteria2 ]] || return 1
    valid_range "$range" && valid_listen_port "$listen_port" || return 1
    printf '%s\t%s\t%s\t%s\t%s\n' "$name" "$range" "$listen_port" "$ipv4_enabled" "$ipv6_enabled"
}

apply_iptables_family() {
    local bin="$1" family="$2" name="$3" range="$4" listen_port="$5"
    local chain="EASY_VPN_HOP_${name^^}" expected_range="${range%-*}:${range#*-}"
    local jump_rules jump_line old_range count=0
    [[ -n "$bin" && -x "$bin" ]] || { echo "$family iptables executable not found" >&2; return 1; }
    jump_rules=$("$bin" -t nat -S PREROUTING) || {
        echo "$family iptables nat PREROUTING is unavailable" >&2; return 1;
    }
    if ! "$bin" -t nat -L "$chain" -n >/dev/null 2>&1; then
        "$bin" -t nat -N "$chain" >/dev/null 2>&1 || {
            "$bin" -t nat -L "$chain" -n >/dev/null 2>&1 || return 1
        }
    fi
    # Reconcile stale/double PREROUTING jumps owned by this tool only.
    while IFS= read -r jump_line; do
        [[ "$jump_line" == *"-j ${chain}"* ]] || continue
        if [[ "$jump_line" =~ --dport[[:space:]]+([0-9]{1,5}):([0-9]{1,5}) ]]; then
            old_range="${BASH_REMATCH[1]}:${BASH_REMATCH[2]}"
            if [[ "$old_range" == "$expected_range" && $count -eq 0 ]]; then
                count=1
            else
                "$bin" -t nat -D PREROUTING -p udp --dport "$old_range" -j "$chain" >/dev/null 2>&1 || {
                    echo "could not reconcile existing $family PREROUTING jump for $chain" >&2; return 1;
                }
            fi
        else
            echo "refusing unfamiliar $family PREROUTING rule referencing $chain" >&2
            return 1
        fi
    done <<< "$jump_rules"
    "$bin" -t nat -F "$chain" || return 1
    if [[ "$family" == ipv6 ]]; then
        "$bin" -t nat -A "$chain" -p udp -j REDIRECT --to-ports "$listen_port" || return 1
    else
        "$bin" -t nat -A "$chain" -p udp -j DNAT --to-destination ":${listen_port}" || return 1
    fi
    if (( count == 0 )); then
        "$bin" -t nat -A PREROUTING -p udp --dport "$expected_range" -j "$chain" || return 1
    fi
}

apply_iptables_file() {
    local file="$1" identity name range listen_port ipv4_enabled ipv6_enabled
    identity=$(iptables_rule_identity "$file") || { echo "refusing invalid Easy VPN iptables rule file: $file" >&2; return 1; }
    IFS=$'\t' read -r name range listen_port ipv4_enabled ipv6_enabled <<< "$identity"
    if [[ "$ipv4_enabled" == 1 ]]; then
        apply_iptables_family "$IPTABLES_BIN" ipv4 "$name" "$range" "$listen_port" || return 1
    fi
    if [[ "$ipv6_enabled" == 1 ]]; then
        apply_iptables_family "$IP6TABLES_BIN" ipv6 "$name" "$range" "$listen_port" || return 1
    fi
}

case "${1:-}" in
    apply-file)
        [[ $# -eq 2 ]] || exit 2
        case "$2" in *.nft) apply_nft_file "$2" ;; *.iptables) apply_iptables_file "$2" ;; *) exit 2 ;; esac
        ;;
    apply-all)
        shopt -s nullglob
        files=("${RULE_DIR}"/*.nft)
        failed=0
        for file in "${files[@]}"; do apply_nft_file "$file" || failed=1; done
        files=("${RULE_DIR}"/*.iptables)
        for file in "${files[@]}"; do apply_iptables_file "$file" || failed=1; done
        exit "$failed"
        ;;
    *) echo "usage: $0 {apply-file PATH|apply-all}" >&2; exit 2 ;;
esac
EOF_HOP_RESTORE
    chmod 0750 "$tmp" || { rm -f "$tmp"; return 1; }
    mv -f -- "$tmp" "$helper" || { rm -f "$tmp"; return 1; }
    mark_owned "$helper"

    tmp=$(mktemp "${SYSTEMD_DIR}/.easy-vpn-port-hop.XXXXXX") || return 1
    cat > "$tmp" <<EOF_HOP_SERVICE
[Unit]
Description=Easy VPN port hopping rule restore (nftables and iptables)
After=local-fs.target nftables.service
Before=${SERVICE_UNIT}

[Service]
Type=oneshot
RemainAfterExit=yes
Environment=EASY_VPN_ETC=${EASY_VPN_ETC}
Environment=EASY_VPN_NFT_BIN=${nft_bin}
Environment=EASY_VPN_IPTABLES_BIN=${iptables_bin}
Environment=EASY_VPN_IP6TABLES_BIN=${ip6tables_bin}
ExecStart=${helper} apply-all

[Install]
WantedBy=multi-user.target
EOF_HOP_SERVICE
    chmod 0644 "$tmp" || { rm -f "$tmp"; return 1; }
    mv -f -- "$tmp" "$unit" || { rm -f "$tmp"; return 1; }
    mark_owned "$unit"

    tmp=$(mktemp "${dropin_dir}/.port-hop.XXXXXX") || return 1
    cat > "$tmp" <<EOF_HOP_DROPIN
[Unit]
Wants=easy-vpn-port-hop.service
After=easy-vpn-port-hop.service
EOF_HOP_DROPIN
    chmod 0644 "$tmp" || { rm -f "$tmp"; return 1; }
    mv -f -- "$tmp" "$dropin" || { rm -f "$tmp"; return 1; }
    mark_owned "$dropin"

    systemctl daemon-reload || return 1
    systemctl enable easy-vpn-port-hop.service >/dev/null || return 1
}

# Keep the old function name for upgrade scripts that may call it; the service
# now supports both nftables and iptables.
ensure_nft_hop_restore_service() { ensure_port_hop_restore_service "$@"; }

cleanup_port_hop_restore_service() {
    local helper unit dropin_dir dropin file
    local -a remaining_rules=()
    helper="${EASY_VPN_ROOT}/bin/easy-vpn-port-hop-restore"
    unit="${SYSTEMD_DIR}/easy-vpn-port-hop.service"
    dropin_dir="${SYSTEMD_DIR}/${SERVICE_UNIT}.d"
    dropin="${dropin_dir}/30-easy-vpn-port-hop.conf"
    remaining_rules=("${EASY_VPN_ETC}/port-hop/"*.nft "${EASY_VPN_ETC}/port-hop/"*.iptables "${EASY_VPN_ETC}/port-hop/"*.firewall)
    for file in "${remaining_rules[@]}"; do
        [[ -e "$file" || -L "$file" ]] && return 0
    done
    systemctl stop easy-vpn-port-hop.service >/dev/null 2>&1 || true
    systemctl disable easy-vpn-port-hop.service >/dev/null 2>&1 || true
    if is_owned "$dropin"; then rm -f -- "$dropin"; unmark_owned "$dropin"; fi
    if is_owned "$unit"; then rm -f -- "$unit"; unmark_owned "$unit"; fi
    if is_owned "$helper"; then rm -f -- "$helper"; unmark_owned "$helper"; fi
    rmdir "$dropin_dir" 2>/dev/null || true
    systemctl daemon-reload >/dev/null 2>&1 || true
}
cleanup_nft_hop_restore_service() { cleanup_port_hop_restore_service "$@"; }

# Migrate existing nftables/iptables hop installations to the shared boot-time
# restore unit. Existing 1.0.5 command-style iptables files remain readable.
migrate_existing_port_hopping() {
    local name backend range listen_port file seen=0
    for name in $(protocol_fragment_names); do
        range=$(state_get "$(protocol_hop_state_key "$name")" 2>/dev/null || true)
        [[ -n "$range" ]] || continue
        backend=$(state_get "$(protocol_hop_backend_state_key "$name")" 2>/dev/null || true)
        listen_port=$(state_get "$(protocol_hop_listen_state_key "$name")" 2>/dev/null || true)
        case "$backend" in nft|iptables) ;; *)
            echo -e "${YELLOW}[升级提示]${PLAIN} ${name} 的端口跳跃后端记录无效；未自动更改规则。"; return 1 ;;
        esac
        if ! validate_hop_range "$range" || ! validate_user_port "$listen_port"; then
            echo -e "${YELLOW}[升级提示]${PLAIN} ${name} 的端口跳跃状态记录无效；未自动更改规则。"
            return 1
        fi
        if [[ "$backend" == nft ]]; then file="${EASY_VPN_ETC}/port-hop/${name}.nft"; else file="${EASY_VPN_ETC}/port-hop/${name}.iptables"; fi
        if [[ -L "$file" ]]; then
            echo -e "${YELLOW}[升级提示]${PLAIN} ${name} 的规则文件是符号链接；未自动更改。"
            return 1
        fi
        if [[ -e "$file" ]]; then
            if [[ ! -f "$file" ]] || ! is_owned "$file"; then
                echo -e "${YELLOW}[升级提示]${PLAIN} ${name} 的规则文件不安全或不属于 Easy VPN；未自动更改。"
                return 1
            fi
        fi
        if [[ ! -e "$file" ]]; then
            write_hop_persistence_file "$name" "$backend" "$range" "$listen_port" >/dev/null || return 1
        fi
        seen=1
    done
    (( seen )) || return 0
    if ! ensure_port_hop_restore_service || ! systemctl restart easy-vpn-port-hop.service; then
        echo -e "${YELLOW}[升级提示]${PLAIN} 端口跳跃开机恢复服务安装/启动失败；保留现有配置，请检查 ${EASY_VPN_ETC}/port-hop/。"
        return 1
    fi
}

migrate_existing_nft_hopping() { migrate_existing_port_hopping "$@"; }

setup_port_hopping() {
    local name="$1" range="$2" listen_port="$3" server_ip="${4:-}" backend file start end p host_firewall_backend manifest
    local EASY_VPN_FIREWALL_BATCH=1 EASY_VPN_FIREWALL_OWNER_MANIFEST
    [[ -n "$range" ]] || return 0
    [[ -z "$(state_get "$(protocol_hop_state_key "$name")" 2>/dev/null || true)" ]] || {
        echo -e "${RED}[错误]${PLAIN} ${name} 已有端口跳跃记录，请先移除旧范围再重新启用。"
        return 1
    }
    start="${range%-*}"; end="${range#*-}"

    local ipv4_enabled=0 ipv6_enabled=0 iptables_path ip6tables_path
    if command_exists nft; then
        backend=nft
    elif command_exists iptables || command_exists ip6tables; then
        backend=iptables
        iptables_path=$(command -v iptables || true)
        ip6tables_path=$(command -v ip6tables || true)
        if [[ "$server_ip" == *:* ]]; then
            # IPv6-only endpoint: do not install IPv4-only redirects and pretend
            # the port range is usable. Require a working IPv6 NAT table.
            if [[ -n "$ip6tables_path" ]] && "$ip6tables_path" -t nat -S PREROUTING >/dev/null 2>&1; then
                ipv6_enabled=1
            else
                echo -e "${YELLOW}[降级提示]${PLAIN} 当前节点使用 IPv6 地址，但本机没有可用 ip6tables NAT；端口跳跃不可用，将使用单端口模式。"
                return 1
            fi
        else
            if [[ -n "$iptables_path" ]] && "$iptables_path" -t nat -S PREROUTING >/dev/null 2>&1; then
                ipv4_enabled=1
            fi
            if [[ -n "$ip6tables_path" ]] && "$ip6tables_path" -t nat -S PREROUTING >/dev/null 2>&1; then
                ipv6_enabled=1
            fi
            if (( ! ipv4_enabled )); then
                echo -e "${RED}[错误]${PLAIN} 本机没有可用 iptables IPv4 NAT，无法安全配置当前 IPv4 节点的端口跳跃。"
                return 1
            fi
            if (( ! ipv6_enabled )); then
                echo -e "${YELLOW}[提示]${PLAIN} 本机没有可用 ip6tables NAT；当前端口跳跃只覆盖 IPv4。"
            fi
        fi
    else
        echo -e "${RED}[错误]${PLAIN} 未找到 nftables、iptables 或 ip6tables，无法启用端口跳跃。"
        return 1
    fi

    manifest="${EASY_VPN_ETC}/port-hop/${name}.firewall"
    if [[ -e "$manifest" || -L "$manifest" ]]; then
        echo -e "${YELLOW}[安全保留]${PLAIN} 端口跳跃防火墙状态清单已存在：${manifest}；请先完成旧配置清理。"
        return 1
    fi
    if [[ "$backend" == iptables ]]; then
        file=$(write_hop_persistence_file "$name" "$backend" "$range" "$listen_port" "$ipv4_enabled" "$ipv6_enabled") || return 1
    else
        file=$(write_hop_persistence_file "$name" "$backend" "$range" "$listen_port") || return 1
    fi
    if ! (umask 077; : > "$manifest"); then
        rm -f -- "$file"
        unmark_owned "$file"
        return 1
    fi
    chmod 600 "$manifest" || { rm -f -- "$manifest" "$file"; unmark_owned "$file"; return 1; }
    mark_owned "$manifest"
    EASY_VPN_FIREWALL_OWNER_MANIFEST="$manifest"
    state_set "$(protocol_hop_backend_state_key "$name")" "$backend"
    state_set "$(protocol_hop_state_key "$name")" "$range"
    state_set "$(protocol_hop_listen_state_key "$name")" "$listen_port"
    if ! ensure_port_hop_restore_service || ! systemctl restart easy-vpn-port-hop.service; then
        echo -e "${RED}[错误]${PLAIN} 端口跳跃规则校验/加载或开机恢复服务安装失败，正在回滚。"
        remove_port_hopping "$name" || true
        return 1
    fi

    host_firewall_backend=$(firewall_backend)
    if ! firewall_allow_range "$range" udp; then
        echo -e "${YELLOW}[警告]${PLAIN} 无法为 UDP ${range} 添加整段主机防火墙规则，正在回滚本次端口跳跃。"
        if ! remove_port_hopping "$name"; then
            echo -e "${RED}[错误]${PLAIN} 端口跳跃回滚未能完全完成，请立即使用“关闭端口跳跃并恢复单端口”重试。"
        fi
        return 1
    fi
    if [[ "$host_firewall_backend" == "firewalld" ]] && ! firewall-cmd --reload >/dev/null 2>&1; then
        echo -e "${RED}[错误]${PLAIN} firewalld 批量重载失败，正在回滚本次端口跳跃规则。"
        if ! remove_port_hopping "$name"; then
            echo -e "${RED}[错误]${PLAIN} 端口跳跃回滚未能完全完成，请检查 firewalld 并手动清理残留规则。"
        fi
        return 1
    fi
    log_action "[可撤销] ${name} 启用端口跳跃 ${range} -> ${listen_port}/${backend}"
}

remove_port_hopping() {
    local name="$1" range backend listen_port file start end p failed=0 nat_safe_to_forget=0
    local manifest line rec_backend rec_port rec_proto extra rule_backend
    # Defer firewalld reload until all owned per-port rules have been processed.
    local EASY_VPN_FIREWALL_BATCH=1
    range=$(state_get "$(protocol_hop_state_key "$name")" 2>/dev/null || true)
    [[ -n "$range" ]] || return 0
    backend=$(state_get "$(protocol_hop_backend_state_key "$name")" 2>/dev/null || true)
    listen_port=$(state_get "$(protocol_hop_listen_state_key "$name")" 2>/dev/null || true)
    if ! validate_hop_range "$range"; then
        echo -e "${RED}[错误]${PLAIN} ${name} 的端口跳跃状态记录无效：${range}；保留记录，未执行破坏性清理。"
        return 1
    fi
    start="${range%-*}"; end="${range#*-}"
    case "$backend" in
        nft)
            file="${EASY_VPN_ETC}/port-hop/${name}.nft"
            if command_exists nft; then
                local table_name
                # Remove the current Easy VPN table and the legacy table name
                # created by earlier VPS Tool / Easy VPN builds.
                for table_name in "easy_vpn_hop_${name}" "vps_tool_hop_${name}"; do
                    local family
                    for family in inet ip; do
                        if nft delete table "$family" "$table_name" >/dev/null 2>&1; then
                            :
                        elif nft list table "$family" "$table_name" >/dev/null 2>&1; then
                            failed=1
                            echo -e "${YELLOW}[警告]${PLAIN} 无法删除 nft ${family} 端口跳跃表 ${table_name}，已保留状态记录。"
                        fi
                    done
                done
            elif [[ -f "$file" ]]; then
                failed=1
                echo -e "${YELLOW}[警告]${PLAIN} 当前系统没有 nft，无法确认 ${name} 的端口跳跃规则已删除；已保留状态记录。"
            fi
            (( failed == 0 )) && nat_safe_to_forget=1
            ;;
        iptables)
            file="${EASY_VPN_ETC}/port-hop/${name}.iptables"
            local ipv4_enabled=1 ipv6_enabled=0 iptables_path ip6tables_path family bin chain expected_range jump_rules jump_line target_hit j
            local -a rule_args=()
            if [[ -e "$file" || -L "$file" ]]; then
                if [[ -L "$file" || ! -f "$file" ]] || ! is_owned "$file"; then
                    failed=1
                    echo -e "${YELLOW}[安全保留]${PLAIN} iptables 持久化文件不安全或不属于 Easy VPN，拒绝读取/删除：${file}"
                else
                    case "$(sed -n '1p' "$file")" in
                        format=easy-vpn-port-hop-v2)
                            ipv4_enabled=$(sed -n 's/^ipv4=//p' "$file")
                            ipv6_enabled=$(sed -n 's/^ipv6=//p' "$file")
                            if [[ ! "$ipv4_enabled" =~ ^[01]$ || ! "$ipv6_enabled" =~ ^[01]$ ]] || (( ! ipv4_enabled && ! ipv6_enabled )); then
                                failed=1
                                echo -e "${YELLOW}[安全保留]${PLAIN} iptables 状态文件中的地址族标记无效，拒绝清理。"
                            fi
                            ;;
                        format=easy-vpn-port-hop-v1) ipv4_enabled=1; ipv6_enabled=0 ;;
                        iptables\ -t\ nat\ -N\ *) ipv4_enabled=1; ipv6_enabled=0 ;;
                        *) failed=1; echo -e "${YELLOW}[安全保留]${PLAIN} 未知 iptables 状态格式，拒绝清理。" ;;
                    esac
                fi
            fi
            iptables_path=$(command -v iptables || true)
            ip6tables_path=$(command -v ip6tables || true)
            chain="EASY_VPN_HOP_${name^^}"; expected_range="${start}:${end}"
            for family in ipv4 ipv6; do
                if [[ "$family" == ipv4 && "$ipv4_enabled" == 1 ]]; then bin="$iptables_path"
                elif [[ "$family" == ipv6 && "$ipv6_enabled" == 1 ]]; then bin="$ip6tables_path"
                else continue
                fi
                if [[ -z "$bin" || ! -x "$bin" ]]; then
                    failed=1
                    echo -e "${YELLOW}[警告]${PLAIN} 缺少 ${family} 的 iptables 工具，无法确认端口跳跃规则已删除。"
                    continue
                fi
                if ! "$bin" -t nat -S PREROUTING >/dev/null 2>&1; then
                    # A missing nat table is safe only when the tool-owned chain is also absent.
                    if "$bin" -t nat -L "$chain" -n >/dev/null 2>&1; then
                        failed=1
                        echo -e "${YELLOW}[警告]${PLAIN} 无法检查 ${family} NAT 规则，保留状态供重试。"
                    fi
                    continue
                fi
                # First remove the exact expected jump, then remove any stale jump
                # whose target is this tool-owned chain (for example after a range
                # change interrupted between the old/new PREROUTING operations).
                while "$bin" -t nat -C PREROUTING -p udp --dport "$expected_range" -j "$chain" >/dev/null 2>&1; do
                    "$bin" -t nat -D PREROUTING -p udp --dport "$expected_range" -j "$chain" >/dev/null 2>&1 || { failed=1; break; }
                done
                if (( failed == 0 )); then
                    jump_rules=$("$bin" -t nat -S PREROUTING 2>/dev/null) || { failed=1; jump_rules=""; }
                    while IFS= read -r jump_line; do
                        [[ "$jump_line" == "-A PREROUTING "* ]] || continue
                        rule_args=()
                        read -r -a rule_args <<< "${jump_line#-A PREROUTING }"
                        target_hit=0
                        for ((j=0; j+1<${#rule_args[@]}; j++)); do
                            if [[ "${rule_args[$j]}" == -j || "${rule_args[$j]}" == -g ]]; then
                                [[ "${rule_args[$((j+1))]}" == "$chain" ]] && target_hit=1
                            fi
                        done
                        if (( target_hit )); then
                            "$bin" -t nat -D PREROUTING "${rule_args[@]}" >/dev/null 2>&1 || { failed=1; break; }
                        fi
                    done <<< "$jump_rules"
                fi
                if (( failed == 0 )) && "$bin" -t nat -L "$chain" -n >/dev/null 2>&1; then
                    "$bin" -t nat -F "$chain" >/dev/null 2>&1 || { failed=1; continue; }
                    "$bin" -t nat -X "$chain" >/dev/null 2>&1 || { failed=1; continue; }
                fi
            done
            # Keep distro-managed firewall snapshots synchronized when available.
            if (( failed == 0 )) && command_exists netfilter-persistent; then
                netfilter-persistent save >/dev/null 2>&1 || echo -e "${YELLOW}[提示]${PLAIN} 系统 netfilter-persistent 快照更新失败；Easy VPN 独立规则文件仍会用于启动恢复。"
            fi
            (( failed == 0 )) && nat_safe_to_forget=1
            ;;
        *)
            failed=1
            echo -e "${YELLOW}[警告]${PLAIN} ${name} 的端口跳跃后端记录未知：${backend}；已保留状态记录。"
            ;;
    esac

    # Once the NAT redirect has been confirmed removed, drop its boot-persistence
    # file immediately. If host-firewall cleanup later fails, keep state/ownership
    # metadata for retry but do not resurrect the redirect on the next reboot.
    if (( nat_safe_to_forget )) && [[ -e "$file" || -L "$file" ]]; then
        if [[ -f "$file" && ! -L "$file" ]] && is_owned "$file"; then
            if rm -f -- "$file"; then
                unmark_owned "$file"
            else
                failed=1
                echo -e "${YELLOW}[警告]${PLAIN} 无法删除已停用的端口跳跃持久化文件 ${file}；已保留状态记录。"
            fi
        else
            failed=1
            echo -e "${YELLOW}[安全保留]${PLAIN} 持久化文件不属于 Easy VPN 或格式不安全：${file}；拒绝删除。"
        fi
    fi

    local firewalld_rules_changed=0 rule_marker
    manifest="${EASY_VPN_ETC}/port-hop/${name}.firewall"
    if [[ -e "$manifest" || -L "$manifest" ]]; then
        if [[ -L "$manifest" || ! -f "$manifest" ]] || ! is_owned "$manifest"; then
            failed=1
            echo -e "${YELLOW}[安全保留]${PLAIN} 端口跳跃防火墙状态清单不安全或不属于 Easy VPN：${manifest}；拒绝删除。"
        else
            # Do not shrink the ownership manifest while the operation is in progress.
            # If any deletion/reload fails, keeping every original entry makes retry safe:
            # entries already absent will return success on the next pass.
            while IFS= read -r line || [[ -n "$line" ]]; do
                [[ -n "$line" ]] || continue
                rec_backend=""; rec_port=""; rec_proto=""; extra=""
                IFS='|' read -r rec_backend rec_port rec_proto extra <<< "$line"
                if [[ -n "$extra" || ! "$rec_backend" =~ ^(ufw|firewalld)$ || "$rec_proto" != udp ]]; then
                    failed=1
                    echo -e "${YELLOW}[安全保留]${PLAIN} 端口跳跃防火墙清单中存在无效条目，已保留以供人工检查。"
                    continue
                fi
                if [[ "$rec_port" =~ ^[0-9]{1,5}-[0-9]{1,5}$ ]]; then
                    if [[ "$rec_port" != "$range" ]] || ! validate_firewall_port_range "$rec_port"; then
                        failed=1
                        echo -e "${YELLOW}[安全保留]${PLAIN} 端口跳跃防火墙清单范围与当前状态不一致，已保留以供人工检查。"
                        continue
                    fi
                    if firewall_remove_owned_range "$rec_backend" "$rec_port" "$rec_proto"; then
                        [[ "$rec_backend" == firewalld ]] && firewalld_rules_changed=1
                    else
                        failed=1
                        echo -e "${YELLOW}[警告]${PLAIN} ${name} 的 UDP ${rec_port} 整段防火墙规则未能精确删除，已保留清单以便重试。"
                    fi
                elif validate_port_any "$rec_port" && (( rec_port >= start && rec_port <= end )); then
                    # Backward compatibility with per-port manifests from previous releases.
                    if firewall_remove_owned_rule "$rec_backend" "$rec_port" "$rec_proto"; then
                        [[ "$rec_backend" == firewalld ]] && firewalld_rules_changed=1
                    else
                        failed=1
                        echo -e "${YELLOW}[警告]${PLAIN} ${name} 的 UDP ${rec_port} 防火墙规则未能精确删除，已保留清单以便重试。"
                    fi
                else
                    failed=1
                    echo -e "${YELLOW}[安全保留]${PLAIN} 端口跳跃防火墙清单中的端口不在当前范围内，已保留以供人工检查。"
                fi
            done < "$manifest"
        fi
    else
        # Backward compatibility: versions <= 1.0.5 recorded each owned port separately.
        for ((p=start; p<=end; p++)); do
            rule_marker="${EASY_VPN_STATE}/firewall/udp_${p}.rule"
            [[ -f "$rule_marker" && ! -L "$rule_marker" ]] || continue
            rule_backend=$(sed -n '1p' "$rule_marker" 2>/dev/null || true)
            if firewall_remove_owned_rules "$p" udp; then
                [[ "$rule_backend" == firewalld ]] && firewalld_rules_changed=1
            else
                failed=1
                echo -e "${YELLOW}[警告]${PLAIN} ${name} 的 UDP ${p} 防火墙规则未能精确删除，已保留端口跳跃记录。"
            fi
        done
    fi
    if (( firewalld_rules_changed )) && ! firewall-cmd --reload >/dev/null 2>&1; then
        failed=1
        echo -e "${YELLOW}[警告]${PLAIN} firewalld 批量重载失败，已保留端口跳跃记录和所有权清单以便重试。"
    fi
    if (( failed == 0 )) && [[ -f "$manifest" && ! -L "$manifest" ]] && is_owned "$manifest"; then
        rm -f -- "$manifest"
        unmark_owned "$manifest"
    fi

    if (( failed )); then
        log_action "[警告] ${name} 端口跳跃 ${range} 撤销未完全成功，保留状态记录等待重试"
        return 1
    fi

    state_unset "$(protocol_hop_state_key "$name")"
    state_unset "$(protocol_hop_backend_state_key "$name")"
    state_unset "$(protocol_hop_listen_state_key "$name")"
    cleanup_port_hop_restore_service
    log_action "[已撤销] ${name} 端口跳跃 ${range}"
    return 0
}

check_protocol_resources() {
    local target_protocols=("$@") protocol_count=0 name mem_mb root_mb swap_mb cpu_count
    local mem_pass mem_warn root_pass root_warn blocked=0 warn=0 confirm action buf_warn=0
    for name in $(protocol_fragment_names); do
        state_exists "protocol_${name}" && ((protocol_count+=1))
    done
    for name in "${target_protocols[@]}"; do
        if ! state_exists "protocol_${name}"; then
            ((protocol_count+=1))
        fi
    done
    (( protocol_count < 1 )) && protocol_count=1
    mem_mb=$(get_mem_available_mb)
    root_mb=$(get_root_free_mb)
    swap_mb=$(current_swap_mb)
    cpu_count=$(nproc 2>/dev/null || echo 1)

    if (( protocol_count == 1 )); then
        mem_pass=128; mem_warn=96
        root_pass=512; root_warn=300
    elif (( protocol_count == 2 )); then
        mem_pass=192; mem_warn=128
        root_pass=800; root_warn=500
    else
        mem_pass=256; mem_warn=192
        root_pass=800; root_warn=500
    fi

    echo -e "${CYAN}[资源预检]${PLAIN} 可用内存 ${mem_mb} MiB / 根分区 ${root_mb} MiB / Swap ${swap_mb} MiB / CPU ${cpu_count} / 协议数 ${protocol_count}"

    if (( mem_mb < mem_warn )); then
        if (( swap_mb >= 512 )); then
            echo -e "${YELLOW}[警告]${PLAIN} 可用内存低于当前协议数的拦截阈值，但已有 Swap ≥ 512 MiB；Swap 只是缓冲，速度远低于真实内存。"
            warn=1
        else
            blocked=1
        fi
    elif (( mem_mb < mem_pass )); then
        warn=1
        echo -e "${YELLOW}[警告]${PLAIN} 可用内存 ${mem_mb} MiB 处于警告区，协议数越多越容易出现 OOM。"
    fi
    if (( root_mb < root_warn )); then
        blocked=1
    elif (( root_mb < root_pass )); then
        warn=1
        echo -e "${YELLOW}[警告]${PLAIN} 根分区可用空间 ${root_mb} MiB 处于警告区。"
    fi

    local tcp_wmem_max wmem_default threshold
    tcp_wmem_max=$(sysctl -n net.ipv4.tcp_wmem 2>/dev/null | awk '{print $NF}' || echo 0)
    wmem_default=$(sysctl -n net.core.wmem_default 2>/dev/null || echo 0)
    # sysctl reports tcp_wmem / wmem_default in bytes; convert MiB to bytes before comparing.
    threshold=$((mem_mb * 1024 * 1024 / 8))
    if [[ "$tcp_wmem_max" =~ ^[0-9]+$ ]] && (( tcp_wmem_max >= threshold )); then buf_warn=1; fi
    if [[ "$wmem_default" =~ ^[0-9]+$ ]] && (( wmem_default >= threshold )); then buf_warn=1; fi
    if (( buf_warn )); then
        echo -e "${YELLOW}[警告]${PLAIN} 当前内核缓冲区上限相对可用内存偏大，高并发时可能增加内存压力；建议手动在 /etc/sysctl.conf 中适当调小 net.ipv4.tcp_wmem 和 net.core.wmem_default。"
    fi

    if (( blocked )); then
        if [[ "${EASY_VPN_FORCE_DEPLOY:-0}" == "1" ]]; then
            echo -e "${YELLOW}[强制继续]${PLAIN} 已按用户要求强制继续，当前资源不足可能导致 OOM 或磁盘耗尽。"
            return 0
        fi
        echo -e "${RED}[拦截]${PLAIN} 当前资源低于安全部署阈值。"
        echo "  1. 增加 Swap：可调用现有 Swap 管理功能；Swap 只作缓冲。"
        echo "  2. 释放磁盘：du -xh / --max-depth=1 | sort -h | tail"
        echo "  3. 明确设置 EASY_VPN_FORCE_DEPLOY=1 可强制继续（风险自负）。"
        if [[ "${EASY_VPN_PIPELINE:-0}" == "1" ]]; then
            echo -e "${RED}[流水线]${PLAIN} 资源处于拦截区，按既有语义直接中止，不等待输入。"
            return 1
        fi
        if ! IFS= read -r -p "现在尝试增加 Swap？[y/N]: " action; then
            action=""
        fi
        if [[ "$action" =~ ^[Yy]$ ]]; then
            local recommended
            recommended=$(recommend_managed_swap_mb)
            if (( recommended >= 256 )); then
                ensure_managed_swap "$recommended" || return 1
                mem_mb=$(get_mem_available_mb)
                swap_mb=$(current_swap_mb)
                if (( mem_mb < mem_warn && swap_mb < 512 )); then return 1; fi
                if (( root_mb < root_warn )); then return 1; fi
                echo -e "${GREEN}[继续]${PLAIN} Swap 调整后允许继续。"
                return 0
            fi
        fi
        return 1
    fi

    if (( warn )); then
        if [[ "${EASY_VPN_PIPELINE:-0}" == "1" ]]; then
            echo -e "${YELLOW}[流水线]${PLAIN} 资源处于警告区，按流水线语义继续，不等待输入。"
            return 0
        fi
        if ! IFS= read -r -p "资源处于警告区，仍要继续部署？[y/N]: " confirm; then
            confirm=""
        fi
        [[ "$confirm" =~ ^[Yy]$ ]] || return 1
    fi
    echo -e "${GREEN}[通过]${PLAIN} 资源预检通过。"
    return 0
}

node_info_value() {
    local file="$1" key="$2"
    awk -v k="$key" 'index($0, k ": ") == 1 { print substr($0, length(k) + 3); exit }' "$file"
}

node_info_share_link() {
    local file="$1"
    awk '/^【一键导入分享链接】:/{getline; print; exit}' "$file"
}

yaml_quote() {
    jq -Rn --arg v "$1" '$v'
}

install_qrencode_dependency() {
    local install_output install_rc=0 choice
    if command_exists qrencode; then
        local qr_path qr_version
        qr_path=$(command -v qrencode)
        qr_version=$(qrencode --version 2>&1 | head -n1 || true)
        if [[ -n "$qr_version" ]]; then
            echo -e "${GREEN}[已安装]${PLAIN} qrencode 已安装：${qr_version}（${qr_path}）"
        else
            echo -e "${GREEN}[已安装]${PLAIN} qrencode 已安装：${qr_path}"
        fi
        return 0
    fi

    if [[ -n "${EASY_VPN_PIPELINE:-}" ]] || [[ ! -t 1 ]]; then
        echo -e "${YELLOW}[提示]${PLAIN} 当前为非交互环境，已跳过二维码依赖安装。"
        return 0
    fi

    echo -e "${YELLOW}[提示]${PLAIN} 显示二维码需要 qrencode，当前未安装。"
    read -rp "是否现在安装？（约几百 KB，仅安装这一个包）[Y/n]: " choice || { echo -e "${YELLOW}[取消]${PLAIN} 未读取到确认，已取消依赖安装。"; return 1; }
    if [[ "$choice" =~ ^[Nn]$ ]]; then
        echo -e "${YELLOW}[提示]${PLAIN} 已跳过安装。"
        return 0
    fi

    if command_exists apt-get; then
        install_output=$(DEBIAN_FRONTEND=noninteractive apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y qrencode 2>&1) || install_rc=$?
    elif command_exists dnf; then
        install_output=$(dnf install -y qrencode 2>&1) || install_rc=$?
    elif command_exists yum; then
        install_output=$(yum install -y qrencode 2>&1) || install_rc=$?
    else
        install_rc=127
        install_output="未找到 apt-get、dnf 或 yum。"
    fi

    if (( install_rc != 0 )) || ! command_exists qrencode; then
        echo -e "${RED}[错误]${PLAIN} qrencode 安装失败。"
        [[ -n "$install_output" ]] && echo "$install_output" | tail -n 8
        if command_exists apt-get; then
            echo "手动安装命令：apt install -y qrencode"
        elif command_exists dnf; then
            echo "手动安装命令：dnf install -y qrencode"
        elif command_exists yum; then
            echo "手动安装命令：yum install -y qrencode"
        else
            echo "手动安装命令：请使用当前发行版的软件包管理器安装 qrencode。"
        fi
        return 0
    fi
    echo -e "${GREEN}[成功]${PLAIN} qrencode 安装完成。"
}

display_protocol_qr() {
    local name="$1" file link
    [[ -n "${EASY_VPN_PIPELINE:-}" ]] && return 0
    [[ -t 1 ]] || return 0
    if ! command_exists qrencode; then
        echo -e "${YELLOW}[提示]${PLAIN} 显示二维码需要 qrencode，当前未安装；请进入“其他与诊断 → 二维码”并执行第 1 项安装依赖。"
        return 0
    fi
    file=$(protocol_node_info_file "$name") || return 1
    [[ -f "$file" ]] || return 1
    link=$(node_info_share_link "$file")
    [[ -n "$link" ]] || { echo -e "${YELLOW}[提示]${PLAIN} ${name} 未找到可生成二维码的分享链接。"; return 0; }
    echo -e "${CYAN}[${name}] 节点二维码：${PLAIN}"
    printf '%s\n' "$link" | qrencode -t ANSIUTF8
}

qr_menu() {
    local choice
    while true; do
        clear
        echo -e "${CYAN}====================================================${PLAIN}"
        echo -e "${CYAN}                    二维码                         ${PLAIN}"
        echo -e "${CYAN}====================================================${PLAIN}"
        if command_exists qrencode; then
            echo -e "  当前状态：${GREEN}qrencode 已安装${PLAIN}"
        else
            echo -e "  当前状态：${YELLOW}qrencode 未安装${PLAIN}"
        fi
        echo -e "${CYAN}----------------------------------------------------${PLAIN}"
        echo -e "  ${GREEN}1. 安装 / 检查二维码依赖（qrencode）${PLAIN}"
        echo -e "  ${GREEN}2. 显示节点二维码${PLAIN}"
        echo -e "  ${CYAN}----------------------------------------------------${PLAIN}"
        echo -e "  ${RED}0. 返回${PLAIN}"
        echo -e "${CYAN}====================================================${PLAIN}"
        read -rp "请选择 [0-2]: " choice || return 0
        case "$choice" in
            1) install_qrencode_dependency || true; read -rp "按回车继续..." || return 0 ;;
            2)
                if ! command_exists qrencode; then
                    echo -e "${YELLOW}[提示]${PLAIN} 当前未安装 qrencode，请先执行第 1 项安装依赖。"
                else
                    show_protocol_qr_menu || true
                fi
                read -rp "按回车继续..." || return 0
                ;;
            0) return 0 ;;
            *) echo -e "${RED}[错误]${PLAIN} 无效选项。"; sleep 1 ;;
        esac
    done
}

show_protocol_qr_menu() {
    local choices=() name choice idx
    for name in $(protocol_fragment_names); do
        state_exists "protocol_${name}" && choices+=("$name")
    done
    (( ${#choices[@]} )) || { echo "暂无已部署协议。"; return 1; }
    echo "请选择要显示二维码的协议："
    for idx in "${!choices[@]}"; do echo "  $((idx+1)). ${choices[$idx]}"; done
    echo "  0. 返回"
    read -rp "请选择: " choice || return 0
    [[ "$choice" =~ ^[0-9]+$ ]] || return 1
    (( choice == 0 )) && return 0
    (( choice >= 1 && choice <= ${#choices[@]} )) || return 1
    display_protocol_qr "${choices[$((choice-1))]}"
}

generate_clash_yaml() {
    local file tmp name node_file server port uuid password sni public_key short_id range
    local count=0
    local -a proxies=()
    local -a names=()
    for name in $(protocol_fragment_names); do
        state_exists "protocol_${name}" && names+=("$name")
    done
    (( ${#names[@]} )) || { echo -e "${YELLOW}[提示]${PLAIN} 暂无已部署协议，无法生成 Clash 配置。"; return 1; }
    command_exists jq || { echo -e "${RED}[错误]${PLAIN} 缺少 jq，无法安全生成 Clash YAML。"; return 1; }

    tmp=$(mktemp "${CONF_DIR}/.clash.yaml.XXXXXX") || { echo -e "${RED}[错误]${PLAIN} 无法创建 Clash/Mihomo 临时配置文件。" >&2; return 1; }
    {
        echo "# Easy VPN 生成的可粘贴 Clash/Mihomo 配置片段"
        echo "proxies:"
    } > "$tmp"

    for name in "${names[@]}"; do
        node_file=$(protocol_node_info_file "$name")
        [[ -f "$node_file" ]] || { echo -e "${YELLOW}[跳过]${PLAIN} ${name} 节点信息缺失。"; continue; }
        server=$(node_info_value "$node_file" '服务器地址')
        # Share URIs require [IPv6]:port, while Clash/Mihomo `server` needs
        # the bare IPv6 literal. Normalize only a fully bracketed address.
        if [[ "$server" == \[*\] ]]; then
            server="${server#[}"
            server="${server%]}"
        fi
        port=$(node_info_value "$node_file" '连接端口')
        [[ -n "$port" ]] || port=$(node_info_value "$node_file" 'UDP 端口')
        sni=$(node_info_value "$node_file" 'SNI')
        case "$name" in
            vless)
                uuid=$(node_info_value "$node_file" '用户 ID (UUID)')
                public_key=$(node_info_value "$node_file" 'PublicKey')
                short_id=$(node_info_value "$node_file" 'ShortId')
                vision_flow=$(node_info_value "$node_file" '流控')
                [[ "$vision_flow" == "已关闭 Vision" ]] && vision_flow=""
                if [[ -z "$server" || -z "$port" || -z "$uuid" || -z "$sni" || -z "$public_key" || -z "$short_id" ]]; then
                    echo -e "${YELLOW}[跳过]${PLAIN} VLESS 缺少必要字段，未输出残缺 YAML。"
                    continue
                fi
                {
                    echo "  - name: EasyVPN-Reality"
                    echo "    type: vless"
                    echo "    server: $(yaml_quote "$server")"
                    echo "    port: ${port}"
                    echo "    uuid: $(yaml_quote "$uuid")"
                    echo "    network: tcp"
                    echo "    tls: true"
                    echo "    udp: true"
                    [[ -n "$vision_flow" ]] && echo "    flow: $(yaml_quote "$vision_flow")"
                    echo "    servername: $(yaml_quote "$sni")"
                    echo "    client-fingerprint: chrome"
                    echo "    reality-opts:"
                    echo "      public-key: $(yaml_quote "$public_key")"
                    echo "      short-id: $(yaml_quote "$short_id")"
                } >> "$tmp"
                proxies+=(EasyVPN-Reality)
                ((count+=1))
                ;;
            hy2)
                password=$(node_info_value "$node_file" '连接密码')
                if [[ -z "$server" || -z "$port" || -z "$password" || -z "$sni" ]]; then
                    echo -e "${YELLOW}[跳过]${PLAIN} Hysteria2 缺少必要字段，未输出残缺 YAML。"
                    continue
                fi
                {
                    echo "  - name: EasyVPN-Hysteria2"
                    echo "    type: hysteria2"
                    echo "    server: $(yaml_quote "$server")"
                    echo "    port: ${port}"
                    echo "    password: $(yaml_quote "$password")"
                    echo "    sni: $(yaml_quote "$sni")"
                    echo "    alpn: [h3]"
                    echo "    skip-cert-verify: true"
                    range=$(state_get "$(protocol_hop_state_key hy2)" 2>/dev/null || true)
                    [[ -n "$range" ]] && echo "    ports: $(yaml_quote "$range")"
                } >> "$tmp"
                proxies+=(EasyVPN-Hysteria2)
                ((count+=1))
                ;;
            tuic)
                uuid=$(node_info_value "$node_file" '用户 ID (UUID)')
                password=$(node_info_value "$node_file" '连接密码')
                if [[ -z "$server" || -z "$port" || -z "$uuid" || -z "$password" || -z "$sni" ]]; then
                    echo -e "${YELLOW}[跳过]${PLAIN} TUIC 缺少必要字段，未输出残缺 YAML。"
                    continue
                fi
                {
                    echo "  - name: EasyVPN-TUICv5"
                    echo "    type: tuic"
                    echo "    server: $(yaml_quote "$server")"
                    echo "    port: ${port}"
                    echo "    uuid: $(yaml_quote "$uuid")"
                    echo "    password: $(yaml_quote "$password")"
                    echo "    congestion-controller: bbr"
                    echo "    udp-relay-mode: native"
                    echo "    alpn: [h3]"
                    echo "    sni: $(yaml_quote "$sni")"
                    echo "    skip-cert-verify: true"
                } >> "$tmp"
                proxies+=(EasyVPN-TUICv5)
                ((count+=1))
                ;;
        esac
    done

    if (( count == 0 )); then
        rm -f "$tmp"
        echo -e "${RED}[错误]${PLAIN} 没有任何协议拥有生成 Clash 配置所需的完整字段。"
        return 1
    fi

    {
        echo
        echo "proxy-groups:"
        echo "  - name: EasyVPN-Auto"
        echo "    type: select"
        echo "    proxies:"
        for name in "${proxies[@]}"; do echo "      - ${name}"; done
        echo
        echo "rules:"
        echo "  - IP-CIDR,127.0.0.0/8,DIRECT,no-resolve"
        echo "  - IP-CIDR,10.0.0.0/8,DIRECT,no-resolve"
        echo "  - IP-CIDR,172.16.0.0/12,DIRECT,no-resolve"
        echo "  - IP-CIDR,192.168.0.0/16,DIRECT,no-resolve"
        echo "  - IP-CIDR6,::1/128,DIRECT,no-resolve"
        echo "  - IP-CIDR6,fc00::/7,DIRECT,no-resolve"
        echo "  - IP-CIDR6,fe80::/10,DIRECT,no-resolve"
        echo "  - GEOIP,CN,DIRECT"
        echo "  - MATCH,EasyVPN-Auto"
    } >> "$tmp"

    chown root:root "$tmp"
    chmod 0600 "$tmp"
    mv -f "$tmp" "${CONF_DIR}/clash.yaml"
    mark_owned "${CONF_DIR}/clash.yaml"
    echo -e "${GREEN}[完成]${PLAIN} Clash/Mihomo 配置已生成：${CONF_DIR}/clash.yaml"
    cat "${CONF_DIR}/clash.yaml"
}

show_clash_yaml() {
    if [[ ! -f "${CONF_DIR}/clash.yaml" ]]; then
        generate_clash_yaml || return 1
        return 0
    fi
    cat "${CONF_DIR}/clash.yaml"
}

protocol_diagnose() {
    local name file tag port proto status backend
    echo -e "${CYAN}================ 协议诊断（只读） ================${PLAIN}"
    if resolve_singbox; then
        echo "[sing-box version]"
        "$SINGBOX_BIN" version 2>&1 || true
    else
        echo -e "${YELLOW}[提示]${PLAIN} 未检测到 sing-box。"
    fi
    echo "[sing-box check]"
    if [[ -f "$CONF_FILE" ]] && resolve_singbox; then
        "$SINGBOX_BIN" check -c "$CONF_FILE" 2>&1 || true
    else
        echo "未找到 ${CONF_FILE}"
    fi
    echo "[inbounds]"
    if [[ -f "$CONF_FILE" ]] && command_exists jq; then
        while IFS=$'\t' read -r tag name port; do
            [[ -n "$tag" ]] || continue
            proto=$(case "$name" in vless) echo vless;; hysteria2) echo hy2;; tuic) echo tuic;; *) echo unknown;; esac)
            status="未监听"
            if [[ "$proto" != unknown ]] && protocol_listener_is_up "$proto"; then status="已监听"; fi
            echo "  tag=${tag} type=${name} port=${port} -> ${status}"
        done < <(jq -r '.inbounds[]? | [.tag,.type,(.listen_port|tostring)] | @tsv' "$CONF_FILE" 2>/dev/null)
    else
        echo "无法读取 config.json"
    fi
    echo "[firewall]"
    backend=$(firewall_backend)
    for name in vless hy2 tuic; do
        state_exists "protocol_${name}" || continue
        port=$(state_get "$(protocol_port_state_key "$name")" 2>/dev/null || true)
        proto=$(protocol_transport "$name") || continue
        if [[ "$backend" != none ]]; then
            if firewall_rule_exists "$backend" "$port" "$proto" >/dev/null 2>&1; then
                status="已放行"
            else
                local firewall_check_status=$?
                if (( firewall_check_status == 2 )); then
                    status="无法确认（读取防火墙服务规则失败）"
                else
                    status="未检测到本机放行"
                fi
            fi
        else
            status="未检测到活动主机防火墙"
        fi
        echo "  ${name}: ${port}/${proto} -> ${status}"
    done
    echo "[云安全组]"
    echo "  请确认云平台安全组至少放行协议对应 TCP/UDP 端口；UDP 协议需放行 UDP。"
    if [[ -f "$CONF_FILE" ]] && command_exists jq; then
        while IFS=$'\t' read -r tag type port; do
            [[ -n "$tag" ]] || continue
            if ! protocol_listener_is_up "$(case "$type" in vless) echo vless;; hysteria2) echo hy2;; tuic) echo tuic;; esac)"; then
                echo -e "${YELLOW}[下一步]${PLAIN} ${tag}:${port} 未监听：systemctl status ${SERVICE_UNIT}；journalctl -u ${SERVICE_UNIT} -n 50 --no-pager -l"
            fi
        done < <(jq -r '.inbounds[]? | [.tag,.type,(.listen_port|tostring)] | @tsv' "$CONF_FILE" 2>/dev/null)
    fi
}

deploy_vless_reality() {
    [[ -n "${EASY_VPN_PIPELINE:-}" ]] || clear
    echo -e "${CYAN}====================================================${PLAIN}"
    echo -e "${CYAN}              [VLESS + Reality]                    ${PLAIN}"
    echo -e "${CYAN}====================================================${PLAIN}"

    local default_port input_port port sni uuid key_pair private_key public_key short_id server_ip uri_host vision_flow suggested_sni custom_sni
    local pipeline_mode="${1:-}"
    local fragment rollback_dir had_fragment=0
    default_port=$(get_random_protocol_port tcp) || { echo -e "${RED}[错误]${PLAIN} 无法找到空闲 TCP 端口。"; return 1; }
    if [[ "$pipeline_mode" == "pipeline" ]]; then
        port="$default_port"
        echo -e "${BLUE}[流水线]${PLAIN} 自动选择空闲 TCP 端口：${port}（无需手动输入）"
    else
        read -rp "端口 [回车使用 ${default_port}，允许 80、443 或 1024-65535]: " input_port || { echo -e "${YELLOW}[取消]${PLAIN} 未读取到端口输入。"; return 1; }
        port="${input_port:-$default_port}"
    fi
    validate_user_port "$port" || { echo -e "${RED}[错误]${PLAIN} 端口无效。"; return 1; }
    port_in_use "$port" tcp && { echo -e "${RED}[错误]${PLAIN} TCP 端口已被占用。"; return 1; }
    state_exists protocol_vless && { echo -e "${YELLOW}[提示]${PLAIN} VLESS + Reality 已经部署。若需更换端口、SNI 或密钥，请先选择“5. 移除协议 / 清理全部”移除它，再重新部署；移除过程中服务会短暂重启，完成后需要重新导入新的节点链接。"; return 1; }
    check_protocol_resources vless || return 1
    vision_flow="xtls-rprx-vision"
    if [[ "$pipeline_mode" != "pipeline" && -z "${EASY_VPN_PIPELINE:-}" ]]; then
        read -rp "启用 Vision 流控？[Y/n]: " vision_choice || { echo -e "${YELLOW}[取消]${PLAIN} 未读取到 Vision 选择。"; return 1; }
        [[ "$vision_choice" =~ ^[Nn]$ ]] && vision_flow=""
    fi

    suggested_sni=$(get_best_sni)
    sni="$suggested_sni"
    if [[ "$pipeline_mode" != "pipeline" && -z "${EASY_VPN_PIPELINE:-}" ]]; then
        read -rp "Reality SNI [回车使用自动建议 ${suggested_sni}，或输入自定义域名]: " custom_sni || {
            echo -e "${YELLOW}[取消]${PLAIN} 未读取到 SNI 输入。"
            return 1
        }
        if [[ -n "${custom_sni//[[:space:]]/}" ]]; then
            custom_sni="${custom_sni,,}"
            if ! validate_sni_hostname "$custom_sni"; then
                echo -e "${RED}[错误]${PLAIN} SNI 必须是合法的完整域名，例如 www.example.com。"
                return 1
            fi
            sni="$custom_sni"
        fi
    fi

    install_singbox || return 1
    prepare_protocol_state
    fragment=$(protocol_fragment_file vless)
    rollback_dir=$(make_temp_dir protocol-vless-rollback) || { echo -e "${RED}[错误]${PLAIN} 无法创建回滚目录，未修改 VLESS 配置。" >&2; return 1; }
    if [[ -f "$fragment" ]]; then cp -a "$fragment" "${rollback_dir}/fragment"; had_fragment=1; fi

    uuid=$(${SINGBOX_BIN} generate uuid)
    key_pair=$(${SINGBOX_BIN} generate reality-keypair)
    private_key=$(awk '/PrivateKey/ {print $2; exit}' <<< "$key_pair")
    public_key=$(awk '/PublicKey/ {print $2; exit}' <<< "$key_pair")
    short_id=$(${SINGBOX_BIN} generate rand --hex 8)
    [[ -n "$uuid" && -n "$private_key" && -n "$public_key" && -n "$short_id" ]] || { rm -rf "$rollback_dir"; echo -e "${RED}[错误]${PLAIN} Reality 密钥生成失败。"; return 1; }

    server_ip="${EASY_VPN_SERVER_IP:-}"
    [[ -n "$server_ip" ]] || server_ip=$(get_sys_ip || true)
    if [[ -z "$server_ip" ]]; then
        if [[ "$pipeline_mode" == "pipeline" || -n "${EASY_VPN_PIPELINE:-}" ]]; then
            echo -e "${RED}[错误]${PLAIN} 自动化模式无法识别公网 IP；请设置 EASY_VPN_SERVER_IP 后重试。"
            rm -rf -- "$rollback_dir"
            return 1
        fi
        read -rp "无法自动识别公网 IP，请手动输入服务器地址：" server_ip || { echo -e "${YELLOW}[取消]${PLAIN} 未读取到服务器地址。"; rm -rf -- "$rollback_dir"; return 1; }
    fi
    [[ -n "$server_ip" ]] || { rm -rf "$rollback_dir"; return 1; }
    server_ip=$(normalize_server_address "$server_ip")
    uri_host=$(format_uri_host "$server_ip")

    local fragment_json
    fragment_json=$(jq -n \
        --argjson port "$port" \
        --arg uuid "$uuid" \
        --arg sni "$sni" \
        --arg private_key "$private_key" \
        --arg short_id "$short_id" \
        --arg flow "$vision_flow" \
        --arg listen "$(protocol_listen_address)" \
        '{type:"vless",tag:"vless-in",listen:$listen,listen_port:$port,users:[{uuid:$uuid} + (if $flow != "" then {flow:$flow} else {} end)],tls:{enabled:true,server_name:$sni,reality:{enabled:true,handshake:{server:$sni,server_port:443},private_key:$private_key,short_id:[$short_id]}}}')

    if ! write_protocol_fragment vless "$fragment_json" || ! regenerate_singbox_config || ! validate_singbox_config; then
        restore_protocol_fragment_transaction vless "$rollback_dir" "$had_fragment" >/dev/null
        rm -rf "$rollback_dir"
        echo -e "${RED}[错误]${PLAIN} VLESS 协议部署失败，已仅回滚本次协议片段。";
        return 1
    fi
    if ! restart_service_and_verify; then
        restore_protocol_fragment_transaction vless "$rollback_dir" "$had_fragment" >/dev/null
        validate_singbox_config >/dev/null 2>&1 || true
        systemctl stop "$SERVICE_UNIT" >/dev/null 2>&1 || true
        systemctl reset-failed "$SERVICE_UNIT" >/dev/null 2>&1 || true
        if [[ -f "$CONF_FILE" ]]; then
            systemctl start "$SERVICE_UNIT" >/dev/null 2>&1 || echo -e "${YELLOW}[警告]${PLAIN} 回滚后的旧协议服务未能重新启动，请根据上方日志排查。"
        fi
        rm -rf "$rollback_dir"
        echo -e "${RED}[错误]${PLAIN} sing-box 启动失败，已仅恢复原协议配置。"
        return 1
    fi
    rm -rf "$rollback_dir"

    firewall_note "$port" tcp
    state_set protocol_vless 1
    state_set protocol_vless_port "$port"
    local vless_link
    vless_link="vless://${uuid}@${uri_host}:${port}?encryption=none&security=reality&sni=${sni}&fp=chrome&pbk=${public_key}&sid=${short_id}&type=tcp"
    [[ -n "$vision_flow" ]] && vless_link+="&flow=${vision_flow}"
    vless_link+="#EasyVPN-Reality"
    if ! write_protocol_node_info vless "===================== 节点连接信息 =====================
协议方案: VLESS + Vision + Reality
运行状态: $(protocol_status_text vless)
服务器地址: ${server_ip}
连接端口: ${port}
用户 ID (UUID): ${uuid}
流控: ${vision_flow:-已关闭 Vision}
SNI: ${sni}
PublicKey: ${public_key}
ShortId: ${short_id}

【一键导入分享链接】:
${vless_link}
========================================================"; then
        echo -e "${YELLOW}[警告]${PLAIN} VLESS 节点信息文件写入失败，但协议配置已生效。"
    fi
    log_action "[可撤销] VLESS-Reality 端口=${port} SNI=${sni}"
    [[ -n "${EASY_VPN_PIPELINE:-}" ]] || clear
    echo -e "${YELLOW}[隐私提醒]${PLAIN} 以下节点信息含有 UUID、密钥和可导入链接，请勿在公共终端或录屏中展示。"
    cat "$(protocol_node_info_file vless)"
    display_protocol_qr vless
    echo -e "\n${GREEN}[成功]${PLAIN} VLESS + Reality 部署完成。"
}

deploy_hysteria2() {
    [[ -n "${EASY_VPN_PIPELINE:-}" ]] || clear
    echo -e "${CYAN}====================================================${PLAIN}"
    echo -e "${CYAN}                [Hysteria 2]                       ${PLAIN}"
    echo -e "${CYAN}====================================================${PLAIN}"

    local default_port input_port port password cert_file key_file server_ip uri_host sni="" hop_range=""
    local fragment rollback_dir had_fragment=0 fragment_json
    default_port=$(get_random_protocol_port udp) || { echo -e "${RED}[错误]${PLAIN} 无法找到空闲 UDP 端口。"; return 1; }
    read -rp "UDP 端口 [回车使用 ${default_port}，允许 80、443 或 1024-65535]: " input_port || { echo -e "${YELLOW}[取消]${PLAIN} 未读取到端口输入。"; return 1; }
    port="${input_port:-$default_port}"
    validate_user_port "$port" || { echo -e "${RED}[错误]${PLAIN} 端口无效。"; return 1; }
    port_in_use "$port" udp && { echo -e "${RED}[错误]${PLAIN} UDP 端口已被占用。"; return 1; }
    state_exists protocol_hy2 && { echo -e "${YELLOW}[提示]${PLAIN} Hysteria 2 已经部署。若需更换端口、SNI 或凭据，请先选择“5. 移除协议 / 清理全部”移除它，再重新部署；移除过程中服务会短暂重启，完成后需要重新导入新的节点链接。"; return 1; }
    if [[ -z "${EASY_VPN_PIPELINE:-}" ]]; then prompt_port_hopping 1; hop_range="${PORT_HOP_RANGE:-}"; else hop_range=""; fi
    check_protocol_resources hy2 || return 1

    install_singbox || return 1
    prepare_protocol_state
    fragment=$(protocol_fragment_file hy2)
    rollback_dir=$(make_temp_dir protocol-hy2-rollback) || { echo -e "${RED}[错误]${PLAIN} 无法创建回滚目录，未修改 Hysteria 2 配置。" >&2; return 1; }
    if [[ -f "$fragment" ]]; then cp -a "$fragment" "${rollback_dir}/fragment"; had_fragment=1; fi

    password=$(${SINGBOX_BIN} generate rand --hex 16)
    cert_file="${CONF_DIR}/hy2_cert.pem"
    key_file="${CONF_DIR}/hy2_key.pem"
    if [[ -e "$cert_file" || -e "$key_file" ]] && { ! is_owned "$cert_file" || ! is_owned "$key_file"; }; then
        rm -rf "$rollback_dir"
        echo -e "${RED}[错误]${PLAIN} 检测到非本工具创建的 Hysteria 2 证书/私钥，拒绝覆盖。"
        return 1
    fi
    if is_owned "$cert_file" || is_owned "$key_file"; then
        rm -f "$cert_file" "$key_file"
        unmark_owned "$cert_file"
        unmark_owned "$key_file"
    fi
    # Use the same SNI in the client link and certificate subject, instead of
    # the old hard-coded bing.com value shared by every deployment.
    sni=$(get_best_sni)
    [[ "$sni" =~ ^[A-Za-z0-9.-]+$ ]] || {
        rm -rf -- "$rollback_dir"
        echo -e "${RED}[错误]${PLAIN} 自动选择的 Hysteria 2 SNI 无效。"
        return 1
    }
    if ! openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
        -keyout "$key_file" -out "$cert_file" -days 365 -subj "/CN=${sni}" -addext "subjectAltName=DNS:${sni}" -addext "extendedKeyUsage=serverAuth" >/dev/null 2>&1; then
        rm -rf "$rollback_dir"
        echo -e "${RED}[错误]${PLAIN} Hysteria 2 TLS 证书生成失败。"
        return 1
    fi
    chmod 0640 "$key_file"
    chmod 0644 "$cert_file"
    chown root:easy-vpn "$key_file" "$cert_file"
    mark_owned "$cert_file"
    mark_owned "$key_file"

    server_ip=$(get_sys_ip || true)
    if [[ -z "$server_ip" ]]; then read -rp "无法自动识别公网 IP，请手动输入服务器地址：" server_ip || { echo -e "${YELLOW}[取消]${PLAIN} 未读取到服务器地址。"; rm -rf -- "$rollback_dir"; return 1; }; fi
    if [[ -z "$server_ip" ]]; then
        rm -f "$cert_file" "$key_file"
        unmark_owned "$cert_file"
        unmark_owned "$key_file"
        rm -rf "$rollback_dir"
        echo -e "${YELLOW}[取消]${PLAIN} 未提供服务器地址，Hysteria 2 部署未继续。"
        return 1
    fi
    server_ip=$(normalize_server_address "$server_ip")
    uri_host=$(format_uri_host "$server_ip")
    fragment_json=$(jq -n \
        --argjson port "$port" \
        --arg password "$password" \
        --arg cert "$cert_file" \
        --arg key "$key_file" \
        --arg listen "$(protocol_listen_address)" \
        '{type:"hysteria2",tag:"hy2-in",listen:$listen,listen_port:$port,users:[{password:$password}],tls:{enabled:true,certificate_path:$cert,key_path:$key}}')

    if ! write_protocol_fragment hy2 "$fragment_json" || ! regenerate_singbox_config || ! validate_singbox_config; then
        restore_protocol_fragment_transaction hy2 "$rollback_dir" "$had_fragment" >/dev/null
        rm -f "$cert_file" "$key_file"
        unmark_owned "$cert_file"
        unmark_owned "$key_file"
        rm -rf "$rollback_dir"
        echo -e "${RED}[错误]${PLAIN} Hysteria 2 部署失败，已仅回滚本次协议片段及本次生成证书。"
        return 1
    fi

    if ! restart_service_and_verify; then
        restore_protocol_fragment_transaction hy2 "$rollback_dir" "$had_fragment" >/dev/null
        if [[ "$had_fragment" == "1" ]]; then
            cp -a "${rollback_dir}/fragment" "$fragment" 2>/dev/null || true
        fi
        rm -f "$cert_file" "$key_file"
        unmark_owned "$cert_file"
        unmark_owned "$key_file"
        systemctl stop "$SERVICE_UNIT" >/dev/null 2>&1 || true
        systemctl reset-failed "$SERVICE_UNIT" >/dev/null 2>&1 || true
        if [[ -f "$CONF_FILE" ]]; then
            systemctl start "$SERVICE_UNIT" >/dev/null 2>&1 || echo -e "${YELLOW}[警告]${PLAIN} 回滚后的旧协议服务未能重新启动，请根据上方日志排查。"
        fi
        rm -rf "$rollback_dir"
        echo -e "${RED}[错误]${PLAIN} Hysteria 2 启动失败，已仅恢复原协议配置。"
        return 1
    fi
    if [[ -n "$hop_range" ]]; then
        if ! setup_port_hopping hy2 "$hop_range" "$port" "$server_ip"; then
            if remove_port_hopping hy2; then
                # Port hopping is optional. If its rules were safely rolled back,
                # keep Hysteria 2 available on its primary UDP port.
                hop_range=""
                echo -e "${YELLOW}[降级运行]${PLAIN} 端口跳跃未能启用，Hysteria 2 仍以单端口模式运行。"
            else
                restore_protocol_fragment_transaction hy2 "$rollback_dir" "$had_fragment" >/dev/null
                systemctl stop "$SERVICE_UNIT" >/dev/null 2>&1 || true
                systemctl reset-failed "$SERVICE_UNIT" >/dev/null 2>&1 || true
                [[ -f "$CONF_FILE" ]] && systemctl start "$SERVICE_UNIT" >/dev/null 2>&1 || true
                rm -rf "$rollback_dir"
                echo -e "${RED}[错误]${PLAIN} 端口跳跃失败且清理未能确认完成；为避免残余规则影响网络，已回滚本次 Hysteria 2 配置。"
                return 1
            fi
        fi
    fi
    rm -rf "$rollback_dir"

    firewall_note "$port" udp
    state_set protocol_hy2 1
    state_set protocol_hy2_port "$port"
    local hy2_link
    hy2_link="hysteria2://${password}@${uri_host}:${port}/?insecure=1&sni=${sni}"
    [[ -n "$hop_range" ]] && hy2_link+="&mport=${hop_range}"
    hy2_link+="#EasyVPN-Hysteria2"
    if ! write_protocol_node_info hy2 "===================== 节点连接信息 =====================
协议方案: Hysteria 2
运行状态: $(protocol_status_text hy2)
服务器地址: ${server_ip}
UDP 端口: ${port}
连接密码: ${password}
SNI: ${sni}
端口跳跃: ${hop_range:-未启用}
说明: 使用本工具生成的自签名证书，因此客户端链接包含 insecure=1。

【一键导入分享链接】:
${hy2_link}
========================================================"; then
        echo -e "${YELLOW}[警告]${PLAIN} Hysteria 2 节点信息文件写入失败，但协议配置已生效。"
    fi
    log_action "[可撤销] Hysteria2 UDP=${port}"
    [[ -n "${EASY_VPN_PIPELINE:-}" ]] || clear
    echo -e "${YELLOW}[隐私提醒]${PLAIN} 以下节点信息含有连接密码和可导入链接，请勿在公共终端或录屏中展示。"
    cat "$(protocol_node_info_file hy2)"
    display_protocol_qr hy2
    echo -e "\n${GREEN}[成功]${PLAIN} Hysteria 2 部署完成。"
}

deploy_tuic_v5() {
    [[ -n "${EASY_VPN_PIPELINE:-}" ]] || clear
    echo -e "${CYAN}====================================================${PLAIN}"
    echo -e "${CYAN}                 [TUIC v5]                         ${PLAIN}"
    echo -e "${CYAN}====================================================${PLAIN}"
    echo -e "${BLUE}[说明]${PLAIN} 面向游戏/实时 UDP 场景，使用原生 UDP 中继；0-RTT 默认关闭以避免重放风险。"

    local default_port input_port port password uuid cert_file key_file server_ip uri_host sni=""
    local fragment rollback_dir had_fragment=0 fragment_json
    default_port=$(get_random_protocol_port udp) || { echo -e "${RED}[错误]${PLAIN} 无法找到空闲 UDP 端口。"; return 1; }
    read -rp "UDP 端口 [回车使用 ${default_port}，允许 80、443 或 1024-65535]: " input_port || { echo -e "${YELLOW}[取消]${PLAIN} 未读取到端口输入。"; return 1; }
    port="${input_port:-$default_port}"
    validate_user_port "$port" || { echo -e "${RED}[错误]${PLAIN} 端口无效。"; return 1; }
    port_in_use "$port" udp && { echo -e "${RED}[错误]${PLAIN} UDP 端口已被占用。"; return 1; }
    state_exists protocol_tuic && { echo -e "${YELLOW}[提示]${PLAIN} TUIC v5 已经部署。若需更换端口、SNI 或凭据，请先选择“5. 移除协议 / 清理全部”移除它，再重新部署；移除过程中服务会短暂重启，完成后需要重新导入新的节点链接。"; return 1; }
    # TUIC v5 clients do not provide a portable native multi-port hopping setting.
    # Port hopping remains available for Hysteria 2 only.
    check_protocol_resources tuic || return 1

    install_singbox || return 1
    prepare_protocol_state
    fragment=$(protocol_fragment_file tuic)
    rollback_dir=$(make_temp_dir protocol-tuic-rollback) || { echo -e "${RED}[错误]${PLAIN} 无法创建回滚目录，未修改 TUIC 配置。" >&2; return 1; }
    if [[ -f "$fragment" ]]; then cp -a "$fragment" "${rollback_dir}/fragment"; had_fragment=1; fi

    uuid=$(${SINGBOX_BIN} generate uuid)
    password=$(${SINGBOX_BIN} generate rand --hex 16)
    cert_file="${CONF_DIR}/tuic_cert.pem"
    key_file="${CONF_DIR}/tuic_key.pem"
    if [[ -e "$cert_file" || -e "$key_file" ]] && { ! is_owned "$cert_file" || ! is_owned "$key_file"; }; then
        rm -rf "$rollback_dir"
        echo -e "${RED}[错误]${PLAIN} 检测到非本工具创建的 TUIC TLS 证书/私钥，拒绝覆盖。"
        return 1
    fi
    if is_owned "$cert_file" || is_owned "$key_file"; then
        rm -f "$cert_file" "$key_file"
        unmark_owned "$cert_file"
        unmark_owned "$key_file"
    fi
    # Match the certificate subject and share-link SNI to a tested candidate;
    # don't reuse the same hard-coded CN and decade-long validity for every node.
    sni=$(get_best_sni)
    [[ "$sni" =~ ^[A-Za-z0-9.-]+$ ]] || {
        rm -rf -- "$rollback_dir"
        echo -e "${RED}[错误]${PLAIN} 自动选择的 TUIC SNI 无效。"
        return 1
    }
    if ! openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
        -keyout "$key_file" -out "$cert_file" -days 365 -subj "/CN=${sni}" -addext "subjectAltName=DNS:${sni}" -addext "extendedKeyUsage=serverAuth" >/dev/null 2>&1; then
        rm -rf "$rollback_dir"
        echo -e "${RED}[错误]${PLAIN} TUIC TLS 证书生成失败。"
        return 1
    fi
    chmod 0640 "$key_file"
    chmod 0644 "$cert_file"
    chown root:easy-vpn "$key_file" "$cert_file"
    mark_owned "$cert_file"
    mark_owned "$key_file"

    [[ -n "$uuid" && -n "$password" ]] || {
        rm -f "$cert_file" "$key_file"
        unmark_owned "$cert_file"
        unmark_owned "$key_file"
        rm -rf "$rollback_dir"
        echo -e "${RED}[错误]${PLAIN} TUIC 凭据生成失败。"
        return 1
    }

    server_ip=$(get_sys_ip || true)
    if [[ -z "$server_ip" ]]; then read -rp "无法自动识别公网 IP，请手动输入服务器地址：" server_ip || { echo -e "${YELLOW}[取消]${PLAIN} 未读取到服务器地址。"; rm -rf -- "$rollback_dir"; return 1; }; fi
    if [[ -z "$server_ip" ]]; then
        rm -f "$cert_file" "$key_file"
        unmark_owned "$cert_file"
        unmark_owned "$key_file"
        rm -rf "$rollback_dir"
        echo -e "${YELLOW}[取消]${PLAIN} 未提供服务器地址，TUIC 部署未继续。"
        return 1
    fi
    server_ip=$(normalize_server_address "$server_ip")
    uri_host=$(format_uri_host "$server_ip")

    fragment_json=$(jq -n \
        --argjson port "$port" \
        --arg uuid "$uuid" \
        --arg password "$password" \
        --arg cert "$cert_file" \
        --arg key "$key_file" \
        --arg listen "$(protocol_listen_address)" \
        '{type:"tuic",tag:"tuic-in",listen:$listen,listen_port:$port,users:[{uuid:$uuid,password:$password}],congestion_control:"bbr",auth_timeout:"3s",zero_rtt_handshake:false,heartbeat:"10s",tls:{enabled:true,alpn:["h3"],certificate_path:$cert,key_path:$key}}')

    if ! write_protocol_fragment tuic "$fragment_json" || ! regenerate_singbox_config || ! validate_singbox_config; then
        restore_protocol_fragment_transaction tuic "$rollback_dir" "$had_fragment" >/dev/null
        rm -f "$cert_file" "$key_file"
        unmark_owned "$cert_file"
        unmark_owned "$key_file"
        rm -rf "$rollback_dir"
        echo -e "${RED}[错误]${PLAIN} TUIC v5 部署失败，已仅回滚本次协议片段及本次生成证书。"
        return 1
    fi
    if ! restart_service_and_verify; then
        restore_protocol_fragment_transaction tuic "$rollback_dir" "$had_fragment" >/dev/null
        rm -f "$cert_file" "$key_file"
        unmark_owned "$cert_file"
        unmark_owned "$key_file"
        systemctl stop "$SERVICE_UNIT" >/dev/null 2>&1 || true
        systemctl reset-failed "$SERVICE_UNIT" >/dev/null 2>&1 || true
        if [[ -f "$CONF_FILE" ]]; then
            systemctl start "$SERVICE_UNIT" >/dev/null 2>&1 || echo -e "${YELLOW}[警告]${PLAIN} 回滚后的旧协议服务未能重新启动，请根据上方日志排查。"
        fi
        rm -rf "$rollback_dir"
        echo -e "${RED}[错误]${PLAIN} sing-box 启动失败，已仅恢复原协议配置。"
        return 1
    fi
    rm -rf "$rollback_dir"

    firewall_note "$port" udp
    state_set protocol_tuic 1
    state_set protocol_tuic_port "$port"
    local tuic_link
    tuic_link="tuic://${uuid}:${password}@${uri_host}:${port}/?congestion_control=bbr&udp_relay_mode=native&alpn=h3&sni=${sni}&allow_insecure=1"
    tuic_link+="#EasyVPN-TUICv5"
    if ! write_protocol_node_info tuic "===================== 节点连接信息 =====================
协议方案: TUIC v5
运行状态: $(protocol_status_text tuic)
服务器地址: ${server_ip}
UDP 端口: ${port}
用户 ID (UUID): ${uuid}
连接密码: ${password}
拥塞控制: BBR
UDP 中继: native（原生 UDP）
0-RTT: 已关闭（避免重放风险）
ALPN: h3
SNI: ${sni}
端口跳跃: 不支持（TUIC v5 客户端无通用原生多端口跳跃配置）
说明: 使用本工具生成的自签名证书，因此客户端链接包含 allow_insecure=1。

【一键导入分享链接】:
${tuic_link}
========================================================"; then
        echo -e "${YELLOW}[警告]${PLAIN} TUIC 节点信息文件写入失败，但协议配置已生效。"
    fi
    log_action "[可撤销] TUICv5 UDP=${port}"
    [[ -n "${EASY_VPN_PIPELINE:-}" ]] || clear
    echo -e "${YELLOW}[隐私提醒]${PLAIN} 以下节点信息含有连接密码和可导入链接，请勿在公共终端或录屏中展示。"
    cat "$(protocol_node_info_file tuic)"
    display_protocol_qr tuic
    echo -e "\n${GREEN}[成功]${PLAIN} TUIC v5 部署完成。"
}

remove_protocol() {
    local name="$1" fragment rollback_dir had_fragment=0 core_usable=0
    case "$name" in vless|hy2|tuic) ;; *) echo -e "${RED}[错误]${PLAIN} 未知协议。"; return 1 ;; esac
    state_exists "protocol_${name}" || { echo -e "${YELLOW}[提示]${PLAIN} ${name} 当前未部署。"; return 1; }
    if resolve_singbox && "$SINGBOX_BIN" version >/dev/null 2>&1; then
        core_usable=1
    else
        echo -e "${YELLOW}[安全降级]${PLAIN} sing-box 缺失或损坏；仍允许移除指定协议配置，但会保持代理服务停止，不会尝试用损坏的内核重启其他协议。" >&2
    fi
    prepare_protocol_state

    fragment=$(protocol_fragment_file "$name")
    [[ -f "$fragment" ]] || { echo -e "${RED}[错误]${PLAIN} ${name} 状态存在但协议片段不存在，拒绝自动删除。"; return 1; }
    rollback_dir=$(make_temp_dir "protocol-${name}-remove-rollback") || { echo -e "${RED}[错误]${PLAIN} 无法创建卸载回滚目录，未删除 ${name} 配置。" >&2; return 1; }
    cp -a "$fragment" "${rollback_dir}/fragment"
    had_fragment=1

    rm -f "$fragment"
    unmark_owned "$fragment"

    if ! regenerate_singbox_config; then
        restore_protocol_fragment_transaction "$name" "$rollback_dir" "$had_fragment" >/dev/null
        rm -rf "$rollback_dir"
        return 1
    fi

    if [[ -f "$CONF_FILE" ]]; then
        if (( core_usable )); then
            if ! validate_singbox_config; then
                restore_protocol_fragment_transaction "$name" "$rollback_dir" "$had_fragment" >/dev/null
                rm -rf "$rollback_dir"
                return 1
            fi
            if ! restart_service_and_verify; then
            restore_protocol_fragment_transaction "$name" "$rollback_dir" "$had_fragment" >/dev/null
            validate_singbox_config >/dev/null 2>&1 || true
            systemctl stop "$SERVICE_UNIT" >/dev/null 2>&1 || true
            systemctl reset-failed "$SERVICE_UNIT" >/dev/null 2>&1 || true
            if [[ -f "$CONF_FILE" ]]; then
                systemctl start "$SERVICE_UNIT" >/dev/null 2>&1 || echo -e "${YELLOW}[警告]${PLAIN} 恢复后的协议服务未能重新启动，请根据上方日志排查。"
            fi
                rm -rf "$rollback_dir"
                echo -e "${RED}[错误]${PLAIN} 移除 ${name} 后服务未能按新配置启动，已恢复该协议。"
                return 1
            fi
        else
            systemctl stop "$SERVICE_UNIT" >/dev/null 2>&1 || true
            systemctl reset-failed "$SERVICE_UNIT" >/dev/null 2>&1 || true
        fi
    fi
    rm -rf "$rollback_dir"
    remove_protocol_resources "$name"
    if (( core_usable == 0 )); then
        echo -e "${YELLOW}[提示]${PLAIN} ${name} 配置已移除。其余协议配置已保留，但 sing-box 服务保持停止；修复或重新安装内核后再启动。" >&2
        return 0
    fi
    if [[ -f "${CONF_DIR}/clash.yaml" ]]; then
        if state_exists protocol_vless || state_exists protocol_hy2 || state_exists protocol_tuic; then
            generate_clash_yaml >/dev/null 2>&1 || echo -e "${YELLOW}[提示]${PLAIN} Clash 配置已失效，请重新生成。"
        else
            if is_owned "${CONF_DIR}/clash.yaml"; then rm -f "${CONF_DIR}/clash.yaml"; unmark_owned "${CONF_DIR}/clash.yaml"; fi
        fi
    fi
    echo -e "${GREEN}[成功]${PLAIN} 已移除 ${name}，其他协议不受影响。"
}

show_protocol_node_info() {
    local name file status
    local shown=0
    for name in $(protocol_fragment_names); do
        if state_exists "protocol_${name}"; then
            file=$(protocol_node_info_file "$name")
            status=$(protocol_status_text "$name")
            echo -e "${CYAN}================ ${name}：${status} ================${PLAIN}"
            if [[ -f "$file" ]]; then
                echo -e "${YELLOW}[隐私提醒]${PLAIN} 以下内容含节点凭据与分享链接。"
                cat "$file"
            else
                echo -e "${YELLOW}[提示]${PLAIN} 节点信息文件不存在。"
            fi
            echo
            shown=1
        fi
    done
    (( shown == 1 )) || echo "暂无已部署协议。"
}

show_protocol_node_info_menu() {
    show_protocol_node_info
    [[ -n "${EASY_VPN_PIPELINE:-}" ]] && return 0
    if [[ -t 0 ]]; then
        local choice
        if IFS= read -r -p "输入 y 重新显示节点二维码，直接回车返回：[y/N]: " choice; then
            if [[ "$choice" =~ ^[Yy]$ ]]; then
                show_protocol_qr_menu
            fi
        fi
    fi
}

protocol_catalog_is_valid() {
    local file="$1"
    [[ -s "$file" ]] || return 1
    jq -e '(.schema_version | type == "number") and (.tool_version | type == "string") and (.protocols | type == "array") and all(.protocols[]; (.id | type == "string") and (.name | type == "string") and (.adapter_version | type == "number") and (.status | type == "string") and (.implemented | type == "boolean"))' "$file" >/dev/null 2>&1
}

protocol_adapter_version_local() {
    local id="$1" version=""
    if protocol_catalog_is_valid "$PROTOCOL_CATALOG_FILE"; then
        version=$(jq -r --arg id "$id" '.protocols[] | select(.id == $id and .implemented == true) | (.adapter_version | tostring)' "$PROTOCOL_CATALOG_FILE" | head -n1)
        [[ -n "$version" && "$version" != "null" ]] && { echo "$version"; return 0; }
    fi
    case "$id" in
        vless-reality) echo 1 ;;
        hysteria2) echo 1 ;;
        tuic-v5) echo 2 ;;
        *) return 1 ;;
    esac
}

protocol_local_id_exists() {
    local id="$1"
    if protocol_catalog_is_valid "$PROTOCOL_CATALOG_FILE"; then
        jq -e --arg id "$id" '.protocols[] | select(.id == $id and .implemented == true)' "$PROTOCOL_CATALOG_FILE" >/dev/null 2>&1
        return $?
    fi
    case "$id" in
        vless-reality|hysteria2|tuic-v5) return 0 ;;
        *) return 1 ;;
    esac
}

singbox_current_version() {
    if ! resolve_singbox; then
        return 1
    fi
    local output version
    output=$("$SINGBOX_BIN" version 2>&1) || return 2
    version=$(grep -oE '[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?' <<<"$output" | head -n1 || true)
    if [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        printf '%s\n' "$version"
        return 0
    fi
    return 2
}

protocol_version_gt() {
    local a="$1" b="$2" a1 a2 a3 b1 b2 b3
    [[ "$a" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]] || return 1
    a1="${BASH_REMATCH[1]}"; a2="${BASH_REMATCH[2]}"; a3="${BASH_REMATCH[3]}"
    [[ "$b" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]] || return 1
    b1="${BASH_REMATCH[1]}"; b2="${BASH_REMATCH[2]}"; b3="${BASH_REMATCH[3]}"
    ((10#$a1 > 10#$b1)) && return 0
    ((10#$a1 < 10#$b1)) && return 1
    ((10#$a2 > 10#$b2)) && return 0
    ((10#$a2 < 10#$b2)) && return 1
    ((10#$a3 > 10#$b3))
}

protocol_update_check() {
    local tmp remote_tool local_tool remote_catalog_tool singbox_local singbox_latest version_url
    local new_protocols=() adapter_updates=() remote_id remote_name remote_ver local_ver item
    local app_update=0 catalog_change=0 singbox_update=0 choice confirm
    version_url="${EASY_VPN_VERSION_URL:-https://raw.githubusercontent.com/${EASY_VPN_GITHUB_USER:-yesok6}/${EASY_VPN_GITHUB_REPO:-easy-vpn}/${PROTOCOL_BRANCH}/VERSION}"

    command_exists curl || { echo -e "${RED}[错误]${PLAIN} 未找到 curl，无法检查协议更新。"; return 1; }
    command_exists jq || { echo -e "${RED}[错误]${PLAIN} 未找到 jq，无法安全解析协议更新清单。"; return 1; }

    tmp=$(make_temp_dir protocol-catalog) || { echo -e "${RED}[错误]${PLAIN} 无法创建协议更新检查临时目录，请检查磁盘空间。" >&2; return 1; }
    if ! curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
        --connect-timeout 5 --max-time 15 --retry 2 -o "${tmp}/remote.json" "$PROTOCOL_CATALOG_URL"; then
        rm -rf "$tmp"
        echo -e "${RED}[错误]${PLAIN} 无法取得远端协议更新清单。"
        return 1
    fi

    if ! protocol_catalog_is_valid "${tmp}/remote.json"; then
        rm -rf "$tmp"
        echo -e "${RED}[错误]${PLAIN} 远端协议更新清单格式无效，已拒绝使用。"
        return 1
    fi

    if ! curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
        --connect-timeout 5 --max-time 15 --retry 2 -o "${tmp}/remote-version" "$version_url"; then
        rm -rf -- "$tmp"
        echo -e "${RED}[错误]${PLAIN} 无法取得远端 Easy VPN 版本号，已停止更新检查。"
        return 1
    fi

    local_tool="$(tr -d '[:space:]' < "${EASY_VPN_ROOT}/VERSION" 2>/dev/null || true)"
    if [[ ! "$local_tool" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        rm -rf -- "$tmp"
        echo -e "${RED}[错误]${PLAIN} 本地 Easy VPN 版本号无效：${local_tool:-缺失}；请先修复安装文件后再检查更新。"
        return 1
    fi
    remote_tool="$(tr -d '[:space:]' < "${tmp}/remote-version")"
    if [[ ! "$remote_tool" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        rm -rf -- "$tmp"
        echo -e "${RED}[错误]${PLAIN} 远端 Easy VPN 版本号无效：${remote_tool}"
        return 1
    fi
    remote_catalog_tool=$(jq -r '.tool_version' "${tmp}/remote.json")

    echo -e "${CYAN}[版本检查]${PLAIN} Easy VPN：当前 v${local_tool}，远端 v${remote_tool}"
    if [[ "$remote_catalog_tool" != "$remote_tool" ]]; then
        echo -e "${YELLOW}[提示]${PLAIN} 远端 VERSION 与协议清单版本不一致（${remote_tool} / ${remote_catalog_tool}）；请项目维护者修正发布包后再试。"
        rm -rf -- "$tmp"
        return 1
    fi
    local catalog_time
    catalog_time=$(jq -r '.updated_at // empty' "${tmp}/remote.json")
    [[ -n "$catalog_time" ]] && echo -e "${BLUE}[清单更新时间]${PLAIN} ${catalog_time}"

    while IFS=$'\t' read -r remote_id remote_name remote_ver; do
        [[ -n "$remote_id" ]] || continue
        if ! protocol_local_id_exists "$remote_id"; then
            new_protocols+=("${remote_name}|${remote_id}|v${remote_ver}")
            catalog_change=1
            continue
        fi
        local_ver=$(protocol_adapter_version_local "$remote_id" 2>/dev/null || true)
        if [[ "$local_ver" =~ ^[0-9]+$ && "$remote_ver" =~ ^[0-9]+$ ]] && (( remote_ver > local_ver )); then
            adapter_updates+=("${remote_name}|${remote_id}|v${local_ver}|v${remote_ver}")
            catalog_change=1
        fi
    done < <(jq -r '.protocols[] | select(.status != "disabled" and .implemented == true) | [.id,.name,(.adapter_version | tostring)] | @tsv' "${tmp}/remote.json")

    if protocol_version_gt "$remote_tool" "$local_tool"; then
        app_update=1
        echo -e "${YELLOW}[更新可用]${PLAIN} Easy VPN 可更新：v${local_tool} → v${remote_tool}"
    elif protocol_version_gt "$local_tool" "$remote_tool"; then
        echo -e "${RED}[版本异常]${PLAIN} 远端 v${remote_tool} 低于本地 v${local_tool}，疑似分支落后或发布错误。为防止降级，已禁止更新和重装。"
        rm -rf -- "$tmp"
        return 1
    fi

    if ((${#new_protocols[@]} > 0)); then
        echo -e "${YELLOW}发现新协议/协议实现：${PLAIN}"
        local item_name item_id item_ver
        for item in "${new_protocols[@]}"; do
            IFS='|' read -r item_name item_id item_ver <<< "$item"
            echo "  ★ ${item_name}（${item_id}，适配 ${item_ver}）"
        done
    fi
    if ((${#adapter_updates[@]} > 0)); then
        echo -e "${YELLOW}发现现有协议适配更新：${PLAIN}"
        local update_name update_id update_old update_new
        for item in "${adapter_updates[@]}"; do
            IFS='|' read -r update_name update_id update_old update_new <<< "$item"
            echo "  ↑ ${update_name}：${update_old} → ${update_new}"
        done
    fi

    # A changed catalog without a higher app release is not safe to install or reinstall.
    if (( catalog_change == 1 && app_update == 0 )); then
        echo -e "${RED}[发布不完整]${PLAIN} 远端清单包含新协议/适配版本，但 Easy VPN 版本号没有提升。为防止同版本文件不一致，本次不提供更新或重装。请维护者先发布新版本。"
        rm -rf -- "$tmp"
        return 1
    fi

    if singbox_local=$(singbox_current_version 2>/dev/null); then
        if singbox_latest=$(latest_singbox_version 2>/dev/null); then
            echo -e "${BLUE}[sing-box]${PLAIN} 当前：v${singbox_local}，最新稳定：v${singbox_latest}"
            if [[ "$singbox_local" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] && [[ "$singbox_latest" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] && protocol_version_gt "$singbox_latest" "$singbox_local"; then
                singbox_update=1
                echo -e "${YELLOW}[内核提示]${PLAIN} sing-box 有新稳定版：v${singbox_local} → v${singbox_latest}（此处不会自动替换内核）"
            fi
        else
            echo -e "${YELLOW}[提示]${PLAIN} 暂时无法取得 sing-box 最新稳定版本，本次跳过内核更新检查。"
        fi
    else
        if resolve_singbox; then
            echo -e "${YELLOW}[提示]${PLAIN} 已检测到 sing-box，但无法解析版本号；请手动执行 ${CYAN}${SINGBOX_BIN} version${PLAIN} 查看。"
        else
            echo -e "${YELLOW}[提示]${PLAIN} 未检测到可执行的 sing-box，跳过内核更新检查。"
        fi
    fi

    echo
    if (( app_update == 1 )); then
        echo -e "${CYAN}可执行操作：${PLAIN}"
        echo "  1. 更新到最新版 v${remote_tool}（保留现有配置和节点数据）"
        echo "  0. 取消并返回"
        read -rp "请选择 [1/0]: " choice || choice="0"
        if [[ "$choice" != 1 ]]; then
            echo -e "${YELLOW}[取消]${PLAIN} 未执行更新。"
            rm -rf -- "$tmp"
            return 0
        fi
        read -rp "确认更新到 Easy VPN v${remote_tool}？[Y/N]: " confirm || confirm="N"
        if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
            echo -e "${YELLOW}[取消]${PLAIN} 已取消更新，当前版本未更改。"
            rm -rf -- "$tmp"
            return 0
        fi
        echo -e "${BLUE}[更新]${PLAIN} 将下载并校验完整文件，先备份当前程序，再进行替换和健康检查。"
    else
        echo -e "${GREEN}[完成]${PLAIN} Easy VPN 程序和已实现协议适配均为最新版本（v${local_tool}）。"
        if (( singbox_update == 1 )); then
            echo -e "${BLUE}[说明]${PLAIN} 仅检测到 sing-box 内核更新；内核更新不会由本选项自动执行。"
        fi
        echo
        echo -e "${CYAN}可执行操作：${PLAIN}"
        echo "  2. 重装当前最新版 v${remote_tool}（修复程序文件；保留配置和节点数据）"
        echo "  0. 取消并返回"
        read -rp "请选择 [2/0]: " choice || choice="0"
        if [[ "$choice" != 2 ]]; then
            echo -e "${YELLOW}[取消]${PLAIN} 未执行重装。"
            rm -rf -- "$tmp"
            return 0
        fi
        read -rp "确认重装 Easy VPN v${remote_tool}？[Y/N]: " confirm || confirm="N"
        if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
            echo -e "${YELLOW}[取消]${PLAIN} 已取消重装，当前版本未更改。"
            rm -rf -- "$tmp"
            return 0
        fi
        echo -e "${BLUE}[重装]${PLAIN} 将重新下载当前最新版，先备份当前程序，再进行替换和健康检查。配置和节点数据不会被删除。"
    fi

    rm -rf -- "$tmp"
    if [[ -x "${EASY_VPN_ROOT}/install.sh" ]]; then
        if bash "${EASY_VPN_ROOT}/install.sh" --update-return; then
            echo -e "${GREEN}[成功]${PLAIN} 文件同步与健康检查完成，正在重新载入最新版菜单……"
            log_action "[协议更新] 用户确认了程序更新/重装，已完成安全同步；正在替换旧菜单进程"
            # The currently running Bash has already parsed the old functions.
            # exec the installed entry point so subsequent menu actions use new code.
            sleep 1
            exec "${EASY_VPN_ROOT}/install.sh"
        else
            echo -e "${RED}[错误]${PLAIN} 更新/重装失败。程序会尝试自动恢复更新前的文件；请查看 ${EASY_VPN_LOG} 日志。"
            return 1
        fi
    else
        echo -e "${RED}[错误]${PLAIN} 找不到本地 Easy VPN 更新入口：${EASY_VPN_ROOT}/install.sh"
        return 1
    fi
}
disable_protocol_hopping_menu() {
    local choices=() name idx choice
    for name in $(protocol_fragment_names); do
        [[ -n "$(state_get "$(protocol_hop_state_key "$name")" 2>/dev/null || true)" ]] && choices+=("$name")
    done
    if (( ${#choices[@]} == 0 )); then
        echo -e "${YELLOW}[提示]${PLAIN} 当前没有启用端口跳跃。"
        return 0
    fi
    echo -e "${CYAN}当前启用端口跳跃：${PLAIN}"
    for idx in "${!choices[@]}"; do
        name="${choices[$idx]}"
        echo "  $((idx + 1)). ${name}（$(state_get "$(protocol_hop_state_key "$name")" 2>/dev/null || echo 未知)）"
    done
    echo "  0. 返回"
    if ! IFS= read -r -p "请选择要关闭的协议 [0-${#choices[@]}]: " choice; then return 1; fi
    [[ "$choice" =~ ^[0-9]+$ ]] || { echo -e "${RED}[错误]${PLAIN} 无效选项。"; return 1; }
    (( choice == 0 )) && return 0
    (( choice >= 1 && choice <= ${#choices[@]} )) || { echo -e "${RED}[错误]${PLAIN} 无效选项。"; return 1; }
    name="${choices[$((choice - 1))]}"
    echo -e "${BLUE}[处理]${PLAIN} 正在撤销 ${name} 的端口跳跃并恢复单端口监听……"
    if ! remove_port_hopping "$name"; then
        echo -e "${RED}[错误]${PLAIN} 端口跳跃撤销没有完全成功；状态记录被保留，请修复后重新执行。"
        return 1
    fi
    systemctl stop "$SERVICE_UNIT" >/dev/null 2>&1 || true
    systemctl reset-failed "$SERVICE_UNIT" >/dev/null 2>&1 || true
    if [[ -f "$CONF_FILE" ]]; then
        if ! validate_singbox_config; then
            echo -e "${RED}[错误]${PLAIN} 当前协议配置校验失败，未自动重启服务。"
            return 1
        fi
        if ! restart_service_and_verify; then
            echo -e "${RED}[错误]${PLAIN} 关闭端口跳跃后服务未能恢复，请查看上方 sing-box 日志。"
            return 1
        fi
    fi
    echo -e "${GREEN}[完成]${PLAIN} ${name} 已关闭端口跳跃并恢复单端口模式。"
}

remove_protocol_menu() {
    remove_or_clean_menu
}

protocol_human_size() {
    local mib="${1:-0}"
    awk -v m="$mib" 'BEGIN {
        if (m >= 1024) printf "%.1f GiB (%d MiB)", m / 1024, m;
        else printf "%d MiB", m;
    }'
}

show_easy_vpn_summary() {
    local hostname os_name arch mem_total_kb mem_available_kb mem_total_mib mem_available_mib
    local disk_total_mib disk_available_mib uptime_text
    hostname=$(hostname 2>/dev/null || printf '未知')
    os_name=$(. /etc/os-release 2>/dev/null; printf '%s' "${PRETTY_NAME:-${ID:-Linux}}")
    arch=$(uname -m 2>/dev/null || printf '未知')
    mem_total_kb=$(awk '/^MemTotal:/ {print $2; exit}' /proc/meminfo 2>/dev/null || true)
    mem_available_kb=$(awk '/^MemAvailable:/ {print $2; exit}' /proc/meminfo 2>/dev/null || true)
    [[ "$mem_total_kb" =~ ^[0-9]+$ ]] || mem_total_kb=0
    [[ "$mem_available_kb" =~ ^[0-9]+$ ]] || mem_available_kb=0
    mem_total_mib=$((mem_total_kb / 1024))
    mem_available_mib=$((mem_available_kb / 1024))
    read -r disk_total_mib disk_available_mib < <(df -Pm / 2>/dev/null | awk 'NR==2 {print $2, $4}') || { disk_total_mib=0; disk_available_mib=0; }
    [[ "${disk_total_mib:-}" =~ ^[0-9]+$ ]] || disk_total_mib=0
    [[ "${disk_available_mib:-}" =~ ^[0-9]+$ ]] || disk_available_mib=0
    uptime_text=$(uptime -p 2>/dev/null || true)
    [[ -n "$uptime_text" ]] || uptime_text="未知"

    echo -e "${CYAN}VPS 概况${PLAIN}  ${hostname} | ${os_name} | ${arch}"
    echo -e "内存：总量 $(protocol_human_size "$mem_total_mib")  |  可用 $(protocol_human_size "$mem_available_mib")"
    echo -e "根分区：总容量 $(protocol_human_size "$disk_total_mib")  |  可用 $(protocol_human_size "$disk_available_mib")"
    echo -e "运行时间：${uptime_text}"
    echo -e "${BLUE}本工具专注于协议搭建：VLESS + Reality、Hysteria 2、TUIC v5；资源数值仅作部署前参考。${PLAIN}"
}

uninstall_protocol_environment() {
    local name file remove_legacy_node_info swap_owned=0
    local -a remaining_hop_files=()
    echo -e "${BLUE}[协议清理]${PLAIN} 仅清理 Easy VPN 自己的协议环境。"

    # Remove optional hopping before stopping or deleting the main proxy.
    # If rule cleanup fails, keep the current sing-box service/config intact so
    # the user can retry rather than turning a partial cleanup into an outage.
    for name in $(protocol_fragment_names); do
        if ! remove_port_hopping "$name"; then
            echo -e "${RED}[错误]${PLAIN} ${name} 的端口跳跃未能完整清理；主代理服务和协议配置保留，请修复防火墙问题后重试。" >&2
            return 1
        fi
    done

    remaining_hop_files=("${EASY_VPN_ETC}/port-hop/"*.nft "${EASY_VPN_ETC}/port-hop/"*.iptables "${EASY_VPN_ETC}/port-hop/"*.firewall)
    for file in "${remaining_hop_files[@]}"; do
        if [[ -e "$file" || -L "$file" ]]; then
            echo -e "${YELLOW}[安全保留]${PLAIN} 发现未能关联到当前协议状态的端口跳跃持久化文件：${file}；为避免重启后规则状态丢失或被意外恢复，主服务与恢复单元均保留，请检查该文件后重试。" >&2
            return 1
        fi
    done
    # Also removes an orphaned helper/unit when no owned rule file remains.
    cleanup_port_hop_restore_service

    # Preflight the managed swap before stopping/removing protocol resources.
    # If ownership is unclear or swapoff fails, abort without partial teardown.
    [[ "$(state_get swap_created 2>/dev/null || true)" == "1" ]] && swap_owned=1
    is_owned "$EASY_VPN_SWAP_PATH" && swap_owned=1
    if (( swap_owned )) || { [[ "$(state_get service_user_owned 2>/dev/null || true)" == "1" ]] && service_user_exists; }; then
        remove_managed_swap || {
            echo -e "${RED}[取消]${PLAIN} Swap 清理未能安全完成；未继续删除协议环境或服务用户。" >&2
            return 1
        }
    fi

    if systemctl is-enabled --quiet "$SERVICE_UNIT" 2>/dev/null; then systemctl disable "$SERVICE_UNIT" >/dev/null 2>&1 || true; fi
    systemctl stop "$SERVICE_UNIT" >/dev/null 2>&1 || true

    firewall_remove_owned_rules || true

    if [[ -f "$NODE_INFO_FILE" ]]; then
        if is_owned "$NODE_INFO_FILE"; then
            rm -f "$NODE_INFO_FILE"
            unmark_owned "$NODE_INFO_FILE"
        else
            echo -e "${YELLOW}[提示]${PLAIN} 检测到旧版节点信息文件 ${NODE_INFO_FILE}，其中可能含有明文节点凭据；round21 已改为按协议分别保存。"
            read -rp "是否删除这个旧版节点信息文件？[y/N]: " remove_legacy_node_info || { echo -e "${YELLOW}[保留]${PLAIN} 未读取到确认，保留旧版节点信息文件。"; }
            if [[ "$remove_legacy_node_info" =~ ^[Yy]$ ]]; then
                rm -f "$NODE_INFO_FILE"
                echo -e "${GREEN}[完成]${PLAIN} 已删除旧版节点信息文件。"
            else
                echo -e "${YELLOW}[保留]${PLAIN} 未删除旧版节点信息文件；新的协议节点信息不使用该文件。"
            fi
        fi
    fi
    for name in $(protocol_fragment_names); do
        file=$(protocol_fragment_file "$name") || continue
        if is_owned "$file"; then rm -f "$file"; unmark_owned "$file"; fi
        file=$(protocol_node_info_file "$name") || continue
        if is_owned "$file"; then rm -f "$file"; unmark_owned "$file"; fi
        state_unset "protocol_${name}"
        state_unset "$(protocol_port_state_key "$name")"
        state_unset "$(protocol_hop_state_key "$name")"
        state_unset "$(protocol_hop_backend_state_key "$name")"
        state_unset "$(protocol_hop_listen_state_key "$name")"
    done
    if is_owned "${CONF_DIR}/clash.yaml"; then rm -f "${CONF_DIR}/clash.yaml"; unmark_owned "${CONF_DIR}/clash.yaml"; fi

    if is_owned "$SERVICE_FILE"; then
        rm -f "$SERVICE_FILE"
        systemctl daemon-reload >/dev/null 2>&1 || true
    fi

    restore_file_backup "$CONF_FILE" protocol_config || true
    restore_file_backup "$SERVICE_FILE" protocol_service_unit || true
    systemctl daemon-reload >/dev/null 2>&1 || true

    for file in \
        "$CONF_DIR/hy2_cert.pem" "$CONF_DIR/hy2_key.pem" \
        "$CONF_DIR/tuic_cert.pem" "$CONF_DIR/tuic_key.pem"; do
        if is_owned "$file"; then rm -f "$file"; unmark_owned "$file"; fi
    done

    if is_owned "${EASY_VPN_ROOT}/bin/sing-box"; then
        rm -f "${EASY_VPN_ROOT}/bin/sing-box"
        unmark_owned "${EASY_VPN_ROOT}/bin/sing-box"
    fi
    if ! remove_owned_service_user; then
        echo -e "${YELLOW}[提示]${PLAIN} 服务用户/Swap 清理未完成；保留相关状态，请修复原因后重试。" >&2
        return 1
    fi
    rmdir "$CONF_DIR" 2>/dev/null || true
    log_action "[已撤销] 清理本工具创建的 sing-box 服务、协议片段、配置和凭据"
}


remove_or_clean_menu() {
    local names=(vless hy2 tuic) name idx choice max
    clear
    echo -e "${CYAN}====================================================${PLAIN}"
    echo -e "${CYAN}        移除协议 / 清理全部                       ${PLAIN}"
    echo -e "${CYAN}====================================================${PLAIN}"
    echo -e "  ${GREEN}1. 清理全部协议与协议环境（移除本工具创建的所有协议）${PLAIN}"
    echo -e "  ${CYAN}----------------------------------------------------${PLAIN}"
    for idx in "${!names[@]}"; do
        name="${names[$idx]}"
        echo -e "  ${GREEN}$((idx + 2)). ${name}（$(protocol_status_text "$name")）${PLAIN}"
    done
    max=$(( ${#names[@]} + 1 ))
    echo -e "  ${CYAN}----------------------------------------------------${PLAIN}"
    echo -e "  ${RED}0. 返回${PLAIN}"
    echo -e "${CYAN}====================================================${PLAIN}"
    read -rp "请选择 [0-${max}]: " choice || return 0
    [[ "$choice" =~ ^[0-9]+$ ]] || { echo -e "${RED}[错误]${PLAIN} 无效选项。"; return 0; }
    (( choice == 0 )) && return 0
    if (( choice == 1 )); then
        local confirm_clean
        read -r -p "这将移除所有 Easy VPN 协议、相关服务和本工具拥有的规则。继续？[y/N]: " confirm_clean || confirm_clean="N"
        if [[ ! "$confirm_clean" =~ ^[Yy]$ ]]; then
            echo -e "${YELLOW}[取消]${PLAIN} 未执行清理。"
            return 0
        fi
        uninstall_protocol_environment || true
        return 0
    fi
    if (( choice >= 2 && choice <= max )); then
        name="${names[$((choice - 2))]}"
        if ! state_exists "protocol_${name}"; then
            echo -e "${YELLOW}[提示]${PLAIN} 该协议当前未部署。"
            return 0
        fi
        remove_protocol "$name" || true
        return 0
    fi
    echo -e "${RED}[错误]${PLAIN} 无效选项。"
}

other_and_diagnose_menu() {
    local choice
    while true; do
        clear
        echo -e "${CYAN}====================================================${PLAIN}"
        echo -e "${CYAN}              其他与诊断                         ${PLAIN}"
        echo -e "${CYAN}====================================================${PLAIN}"
        echo -e "  ${YELLOW}1. 二维码（显示 / 安装依赖）${PLAIN}"
        echo -e "  ${YELLOW}2. 生成 / 查看 Clash / Mihomo 配置${PLAIN}"
        echo -e "  ${YELLOW}3. 协议诊断（只读）${PLAIN}"
        echo -e "  ${YELLOW}4. 关闭端口跳跃并恢复单端口${PLAIN}"
        echo -e "  ${CYAN}----------------------------------------------------${PLAIN}"
        echo -e "  ${RED}0. 返回${PLAIN}"
        echo -e "${CYAN}====================================================${PLAIN}"
        read -rp "请选择 [0-4]: " choice || return 0
        case "$choice" in
            1) qr_menu ;;
            2) show_clash_yaml || true; read -rp "按回车继续..." || return 0 ;;
            3) protocol_diagnose || true; read -rp "按回车继续..." || return 0 ;;
            4) disable_protocol_hopping_menu || true; read -rp "按回车继续..." || return 0 ;;
            0) return 0 ;;
            *) echo -e "${RED}[错误]${PLAIN} 无效选项。"; sleep 1 ;;
        esac
    done
}

protocol_menu() {
    while true; do
        clear
        local status_text choice
        if [[ "${EASY_VPN_HOP_MIGRATION_CHECKED:-0}" != 1 ]]; then
            export EASY_VPN_HOP_MIGRATION_CHECKED=1
            migrate_existing_port_hopping || true
        fi
        systemctl is-active --quiet "$SERVICE_UNIT" 2>/dev/null && status_text="${GREEN}运行中${PLAIN}" || status_text="${RED}未运行/未配置${PLAIN}"
        echo -e "${CYAN}====================================================${PLAIN}"
        echo -e "${CYAN}              Easy VPN 协议搭建工具                      ${PLAIN}"
        show_easy_vpn_summary
        echo -e "服务状态：${status_text}"
        echo -e "${CYAN}----------------------------------------------------${PLAIN}"
        echo -e "  ${GREEN}1. 搭建 VLESS + Reality（TCP）${PLAIN}"
        echo -e "  ${GREEN}2. 搭建 Hysteria 2（QUIC / UDP，支持端口跳跃）${PLAIN}"
        echo -e "  ${GREEN}3. 搭建 TUIC v5（QUIC / UDP，适合实时应用）${PLAIN}"
        echo -e "  ${GREEN}4. 查看节点信息${PLAIN}"
        echo -e "  ${GREEN}5. 移除协议 / 清理全部${PLAIN}"
        echo -e "  ${CYAN}----------------------------------------------------${PLAIN}"
        echo -e "  ${YELLOW}6. 检查更新（程序 / 协议 / 内核）${PLAIN}"
        echo -e "  ${YELLOW}7. 节点工具与诊断（二维码 / Clash 配置 / 端口跳跃）${PLAIN}"
        echo -e "  ${CYAN}----------------------------------------------------${PLAIN}"
        echo -e "  ${RED}0. 退出${PLAIN}"
        echo -e "${CYAN}====================================================${PLAIN}"
        read -rp "请选择 [0-7]: " choice || return 0
        case "$choice" in
            1) deploy_vless_reality || true; read -rp "按回车继续..." || return 0 ;;
            2) deploy_hysteria2 || true; read -rp "按回车继续..." || return 0 ;;
            3) deploy_tuic_v5 || true; read -rp "按回车继续..." || return 0 ;;
            4) show_protocol_node_info_menu || true ;;
            5) remove_or_clean_menu; read -rp "按回车继续..." || return 0 ;;
            6) protocol_update_check || true; read -rp "按回车继续..." || return 0 ;;
            7) other_and_diagnose_menu ;;
            0) break ;;
            *) echo -e "${RED}[错误]${PLAIN} 无效选项。"; sleep 1 ;;
        esac
    done
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    case "${1:-}" in
        --pipeline-reality)
            export EASY_VPN_PIPELINE=1
            deploy_vless_reality pipeline
            ;;
        *) protocol_menu ;;
    esac
fi
