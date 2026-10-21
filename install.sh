#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

CURRENT_VERSION="1.0.19"
# This project has a fixed public repository; users do not need to configure owner/repo.
GITHUB_USER="yesok6"
GITHUB_REPO="easy-vpn"
export EASY_VPN_GITHUB_USER="$GITHUB_USER" EASY_VPN_GITHUB_REPO="$GITHUB_REPO"
EASY_VPN_BRANCH="${EASY_VPN_BRANCH:-main}"
export EASY_VPN_BRANCH
LOCAL_ROOT="${EASY_VPN_ROOT:-/opt/easy-vpn}"
LOCAL_MODULES="${LOCAL_ROOT}/modules"
LOCAL_LIB="${LOCAL_ROOT}/lib"
LOG_DIR="${EASY_VPN_ETC:-/etc/easy-vpn}"
LOG_FILE="${LOG_DIR}/install.log"
GITHUB_SOURCE_MODE_FILE="${LOG_DIR}/github-source-mode"
PROXY_CONSENT_FILE="${LOG_DIR}/allow-unsigned-proxy"
SHORTCUT="${EASY_VPN_SHORTCUT:-/usr/local/bin/vpn}"
# Linux command names are case-sensitive; install both `vpn` and `VPN` for convenience.
UPPERCASE_SHORTCUT="${EASY_VPN_UPPERCASE_SHORTCUT:-${SHORTCUT%/*}/VPN}"
LEGACY_SHORTCUT="${EASY_VPN_LEGACY_SHORTCUT:-${SHORTCUT%/*}/easy-vpn}"
# BASH_SOURCE[0] is unset when this installer is fed to Bash over stdin
# (for example: curl ... | sudo bash). Never index it unguarded under set -u.
SCRIPT_SOURCE="${BASH_SOURCE[0]-}"
SOURCE_DIR=""
if [[ -n "$SCRIPT_SOURCE" ]]; then
    SOURCE_DIR="$(cd -- "$(dirname -- "$SCRIPT_SOURCE")" 2>/dev/null && pwd -P)" || SOURCE_DIR=""
fi

# 可选发布签名公钥（ECDSA P-256，PEM），由维护者运行 tools/release.sh release 注入。
# 当前公钥为空时，官方源仍通过 HTTPS 下载；第三方国内代理必须由用户明确选择并接受未签名风险。
# 配置公钥后，所有远程项目文件都必须匹配 SHA256SUMS 的签名和逐文件哈希。
# 不允许使用普通环境变量覆盖公钥，避免更新流程被意外降级为不校验。
# >>> EASY_VPN_RELEASE_PUBKEY >>>
EASY_VPN_RELEASE_PUBKEY=''
# <<< EASY_VPN_RELEASE_PUBKEY <<<

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; PLAIN='\033[0m'

[[ ${EUID} -eq 0 ]] || { echo -e "${RED}[错误]${PLAIN} 此操作需要 root 权限。请使用：sudo bash install.sh${PLAIN}"; exit 1; }
for path in "$LOCAL_ROOT" "$LOCAL_MODULES" "$LOCAL_LIB" "$LOG_DIR"; do
    [[ ! -L "$path" ]] || { echo -e "${RED}[错误]${PLAIN} 安装路径不能是符号链接：${path}"; exit 1; }
done
mkdir -p "$LOCAL_ROOT" "$LOCAL_MODULES" "$LOCAL_LIB" "$LOG_DIR"
# sing-box runs as an unprivileged account and must be able to traverse the
# install tree to execute /opt/easy-vpn/bin/sing-box. Source files contain no secrets.
chmod 0755 "$LOCAL_ROOT" "$LOCAL_MODULES" "$LOCAL_LIB" || { echo -e "${RED}[错误]${PLAIN} 无法设置安装目录权限。" >&2; exit 1; }

log_action() {
    ( umask 077; touch "$LOG_FILE"; chmod 600 "$LOG_FILE"; printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${1:-}" >> "$LOG_FILE" )
}

proxy_unsigned_consent_saved() {
    local owner mode saved
    [[ -n "${PROXY_CONSENT_FILE:-}" && -f "$PROXY_CONSENT_FILE" && ! -L "$PROXY_CONSENT_FILE" ]] || return 1
    owner=$(stat -c '%u' -- "$PROXY_CONSENT_FILE" 2>/dev/null) || return 1
    mode=$(stat -c '%a' -- "$PROXY_CONSENT_FILE" 2>/dev/null) || return 1
    [[ "$owner" == 0 && "$mode" == 600 ]] || return 1
    IFS= read -r saved < "$PROXY_CONSENT_FILE" || return 1
    [[ "$saved" == "yes" ]]
}

save_proxy_unsigned_consent() {
    local tmp
    tmp=$(mktemp "${LOG_DIR}/.allow-unsigned-proxy.XXXXXX") || return 1
    if ! printf 'yes\n' > "$tmp" || ! chmod 600 "$tmp" || ! mv -f -- "$tmp" "$PROXY_CONSENT_FILE"; then
        rm -f -- "$tmp"
        return 1
    fi
}

persist_github_source_mode() {
    local mode="$1" mode_tmp=""
    mode_tmp=$(mktemp "${LOG_DIR}/.github-source-mode.XXXXXX") || {
        echo -e "${RED}[错误]${PLAIN} 无法创建 GitHub 源配置临时文件。" >&2
        return 1
    }
    if ! printf '%s\n' "$mode" > "$mode_tmp" || ! chmod 600 "$mode_tmp" || ! mv -f -- "$mode_tmp" "$GITHUB_SOURCE_MODE_FILE"; then
        rm -f -- "$mode_tmp"
        echo -e "${RED}[错误]${PLAIN} 无法保存 GitHub 源配置；安装已停止，未开始同步。" >&2
        return 1
    fi
}

configure_github_source_mode() {
    local requested="${EASY_VPN_GITHUB_SOURCE_MODE:-}" configured="direct" consent_saved=0
    proxy_unsigned_consent_saved && consent_saved=1 || true
    if [[ -n "$requested" ]]; then
        case "$requested" in
            china|direct) configured="$requested" ;;
            *) echo -e "${RED}[错误]${PLAIN} EASY_VPN_GITHUB_SOURCE_MODE 仅允许 china 或 direct。" >&2; return 1 ;;
        esac

        # Without a maintainer signature, proxy use is an explicit trust decision.
        # Reject before writing the source mode so a failed first attempt cannot trap future runs.
        if [[ "$configured" == "china" && -z "$EASY_VPN_RELEASE_PUBKEY" && "${EASY_VPN_ALLOW_UNSIGNED_PROXY:-0}" != "1" && "$consent_saved" != "1" ]]; then
            echo -e "${RED}[拒绝]${PLAIN} 当前没有配置发布签名，不能自动信任第三方国内加速源。" >&2
            echo -e "${YELLOW}[提示]${PLAIN} 优先使用 README 中的 GitHub 官方源命令；若明确接受第三方代理以 root 权限提供脚本的风险，再按 README 设置 EASY_VPN_ALLOW_UNSIGNED_PROXY=1。" >&2
            return 1
        fi

        if [[ "$configured" == "china" && -z "$EASY_VPN_RELEASE_PUBKEY" && "${EASY_VPN_ALLOW_UNSIGNED_PROXY:-0}" == "1" ]]; then
            save_proxy_unsigned_consent || {
                echo -e "${RED}[错误]${PLAIN} 无法安全保存国内代理风险确认；未开始同步。" >&2
                return 1
            }
            log_action "[风险确认] 用户明确允许使用未签名的第三方国内加速源；同意记录保存在 ${PROXY_CONSENT_FILE}"
        elif [[ "$configured" == "direct" ]]; then
            # Selecting the official source revokes the previous unsigned-proxy opt-in.
            if [[ -e "$PROXY_CONSENT_FILE" || -L "$PROXY_CONSENT_FILE" ]]; then
                [[ -f "$PROXY_CONSENT_FILE" && ! -L "$PROXY_CONSENT_FILE" ]] || {
                    echo -e "${RED}[错误]${PLAIN} 国内代理确认文件不是安全的普通文件：${PROXY_CONSENT_FILE}" >&2
                    return 1
                }
                rm -f -- "$PROXY_CONSENT_FILE" || return 1
            fi
        fi
    elif [[ -e "$GITHUB_SOURCE_MODE_FILE" || -L "$GITHUB_SOURCE_MODE_FILE" ]]; then
        [[ -f "$GITHUB_SOURCE_MODE_FILE" && ! -L "$GITHUB_SOURCE_MODE_FILE" ]] || {
            echo -e "${RED}[错误]${PLAIN} GitHub 源配置不是安全的普通文件：${GITHUB_SOURCE_MODE_FILE}" >&2; return 1;
        }
        IFS= read -r configured < "$GITHUB_SOURCE_MODE_FILE" || configured=""
        case "$configured" in
            china|direct) ;;
            *) echo -e "${RED}[错误]${PLAIN} GitHub 源配置内容无效，请检查 ${GITHUB_SOURCE_MODE_FILE}。" >&2; return 1 ;;
        esac
        # Repair stale settings written by older builds before they rejected an unsigned proxy.
        # Fall back to official HTTPS instead of leaving the user stuck in an unusable china mode.
        if [[ "$configured" == "china" && -z "$EASY_VPN_RELEASE_PUBKEY" && "${EASY_VPN_ALLOW_UNSIGNED_PROXY:-0}" != "1" ]] && ! proxy_unsigned_consent_saved; then
            echo -e "${YELLOW}[修复]${PLAIN} 发现未确认风险的国内源设置，已切回 GitHub 官方 HTTPS 源。" >&2
            configured="direct"
        fi
    fi

    persist_github_source_mode "$configured" || return 1
    EASY_VPN_GITHUB_SOURCE_MODE="$configured"
    export EASY_VPN_GITHUB_SOURCE_MODE
}

on_error() {
    local rc=$?
    local err_source="${BASH_SOURCE[1]-}"
    [[ -n "$err_source" ]] || err_source="${BASH_SOURCE[0]-main}"
    local err_line="${BASH_LINENO[0]-0}"
    echo -e "${RED}[错误]${PLAIN} 操作失败（退出码 ${rc}，位置 ${err_source}:${err_line}）。"
    echo -e "${YELLOW}[提示]${PLAIN} 详细日志：${LOG_FILE}"
    log_action "[失败] exit=${rc}"
    return "$rc"
}
trap on_error ERR
configure_github_source_mode || exit 1

install_dependencies() {
    local missing=() cmd
    for cmd in curl jq ss openssl tar sha256sum flock; do
        command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
    done
    ((${#missing[@]} == 0)) && return 0
    echo -e "${BLUE}[准备中]${PLAIN} 安装协议模块运行依赖：${missing[*]}"
    if command -v apt-get >/dev/null 2>&1; then
        DEBIAN_FRONTEND=noninteractive apt-get update -y -q
        DEBIAN_FRONTEND=noninteractive apt-get install -y -q curl jq iproute2 openssl tar coreutils util-linux
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y curl jq iproute openssl tar coreutils util-linux
    elif command -v yum >/dev/null 2>&1; then
        yum install -y curl jq iproute openssl tar coreutils util-linux
    else
        echo -e "${RED}[错误]${PLAIN} 未识别 apt/dnf/yum，无法自动安装依赖。"
        return 1
    fi
    for cmd in curl jq ss openssl tar sha256sum flock; do
        command -v "$cmd" >/dev/null 2>&1 || { echo -e "${RED}[错误]${PLAIN} 依赖仍缺失：${cmd}"; return 1; }
    done
}

local_bundle_available() {
    local dir="${1:-}"
    [[ -n "$dir" && -d "$dir" ]] || return 1
    [[ -f "$dir/install.sh" && ! -L "$dir/install.sh" &&
       -f "$dir/lib/common.sh" && ! -L "$dir/lib/common.sh" &&
       -f "$dir/modules/protocol.sh" && ! -L "$dir/modules/protocol.sh" &&
       -f "$dir/protocol_catalog.json" && ! -L "$dir/protocol_catalog.json" ]]
}

raw_direct_base_url() {
    printf 'https://raw.githubusercontent.com/%s/%s/%s' "$GITHUB_USER" "$GITHUB_REPO" "$EASY_VPN_BRANCH"
}

raw_base_url() {
    local direct
    direct=$(raw_direct_base_url)
    if [[ "${EASY_VPN_GITHUB_SOURCE_MODE:-direct}" == "china" ]]; then
        printf 'https://gh-proxy.org/%s' "$direct"
    else
        printf '%s' "$direct"
    fi
}

download_bundle_file() {
    local primary_base="$1" direct_base="$2" file="$3" output="$4" url
    if [[ "${EASY_VPN_GITHUB_SOURCE_MODE:-direct}" == "china" ]]; then
        # Do not append query parameters to the proxy URL: keep its nested target URL intact.
        url="${primary_base}/${file}"
        if curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
            --connect-timeout 10 --max-time 120 --retry 2 -o "$output" "$url"; then
            return 0
        fi
        rm -f -- "$output"
        echo -e "${YELLOW}[国内加速回退]${PLAIN} 加速源下载 ${file} 失败，改用 GitHub 官方源重试。" >&2
        url="${direct_base}/${file}?t=$(date +%s)-${RANDOM}${RANDOM}"
        curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
            --connect-timeout 10 --max-time 120 --retry 2 -o "$output" "$url"
    else
        url="${primary_base}/${file}?t=$(date +%s)-${RANDOM}${RANDOM}"
        curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
            --connect-timeout 10 --max-time 120 --retry 2 -o "$output" "$url"
    fi
}

# Compare stable numeric version components; this is used only to prevent accidental downgrades.
easy_vpn_version_gt() {
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

# 第三方加速代理只允许在“能够校验内容真实性”的前提下使用：
# 脚本最终以 root 身份执行，代理一旦返回被篡改的内容，bash -n / 版本号 / JSON 检查都挡不住。
require_verifiable_remote_source() {
    [[ "${EASY_VPN_GITHUB_SOURCE_MODE:-direct}" == "china" ]] || return 0
    [[ -z "$EASY_VPN_RELEASE_PUBKEY" ]] || return 0
    if [[ "${EASY_VPN_ALLOW_UNSIGNED_PROXY:-0}" == "1" ]] || proxy_unsigned_consent_saved; then
        echo -e "${YELLOW}[警告]${PLAIN} 正在使用未签名的第三方国内加速源；TLS 不能替代维护者发布签名。" >&2
        log_action "[警告] 使用未签名的第三方国内加速源；执行前提为用户明确确认风险"
        return 0
    fi
    echo -e "${RED}[拒绝]${PLAIN} 国内加速模式会让第三方代理提供将以 root 运行的脚本，而当前版本没有发布签名，无法独立验证内容真实性。" >&2
    echo -e "${YELLOW}[提示]${PLAIN} 优先改用 GitHub 官方 HTTPS 源；如明确接受风险，请通过 README 中包含 EASY_VPN_ALLOW_UNSIGNED_PROXY=1 的国内命令重新选择。" >&2
    return 1
}

# 校验已下载到目录 $1 的 SHA256SUMS / SHA256SUMS.sig，并核对其后列出的每个文件哈希。
verify_bundle_signature() {
    local dir="$1"; shift
    local manifest="${dir}/SHA256SUMS" sig_b64="${dir}/SHA256SUMS.sig"
    local sig_bin="${dir}/.SHA256SUMS.sig.bin" pubfile="${dir}/.release-public.pem"
    local file expected actual
    [[ -n "$EASY_VPN_RELEASE_PUBKEY" ]] || return 1
    [[ -s "$manifest" && -s "$sig_b64" ]] || return 1
    printf '%s\n' "$EASY_VPN_RELEASE_PUBKEY" > "$pubfile" || return 1
    openssl base64 -d -A -in "$sig_b64" -out "$sig_bin" 2>/dev/null || { rm -f -- "$pubfile" "$sig_bin"; return 1; }
    if ! openssl dgst -sha256 -verify "$pubfile" -signature "$sig_bin" "$manifest" >/dev/null 2>&1; then
        rm -f -- "$pubfile" "$sig_bin"
        return 1
    fi
    rm -f -- "$pubfile" "$sig_bin"
    for file in "$@"; do
        [[ -f "${dir}/${file}" && ! -L "${dir}/${file}" ]] || return 1
        expected=$(awk -v f="$file" '$2 == f { print $1; exit }' "$manifest")
        [[ "$expected" =~ ^[0-9a-f]{64}$ ]] || return 1
        actual=$(sha256sum -- "${dir}/${file}" | awk '{print $1}')
        [[ "$actual" == "$expected" ]] || return 1
    done
    return 0
}

sync_bundle() (
    set -Eeuo pipefail
    local source_dir="${1:-}" base direct_base temp remote_version bundle_version catalog_version file
    local backup_dir="" backup_has_old=0 keep_backup=0 commit_started=0 transaction_ok=0 rollback_failed=0
    local new_bytes=0 old_bytes=0 root_free_kb=0 log_free_kb=0 root_dev="" log_dev="" margin_bytes=$((1024 * 1024))
    local new_bytes_kb=0 old_bytes_kb=0 margin_kb=0
    local target candidate mode idx rollback_tmp rc
    local -a rels=(install.sh lib/common.sh modules/protocol.sh protocol_catalog.json VERSION)
    local -a target_paths=() candidate_paths=() had_old=() changed_indices=()

    cleanup_sync() {
        rc=$?
        trap - EXIT
        if (( commit_started == 1 && transaction_ok == 0 && ${#changed_indices[@]} > 0 )); then
            echo -e "${YELLOW}[回滚]${PLAIN} 更新后健康检查或文件切换失败，正在恢复旧版程序文件..." >&2
            for ((idx=${#changed_indices[@]}-1; idx>=0; idx--)); do
                local i current_target rel old_file
                i="${changed_indices[$idx]}"
                current_target="${target_paths[$i]}"
                if [[ "${had_old[$i]}" == 1 ]]; then
                    rel="${rels[$i]}"
                    old_file="${backup_dir}/original/${rel}"
                    rollback_tmp=""
                    if [[ -f "$old_file" && ! -L "$old_file" ]]; then
                        rollback_tmp=$(mktemp "${current_target%/*}/.easy-vpn-rollback.XXXXXX" 2>/dev/null) || rollback_tmp=""
                        if [[ -n "$rollback_tmp" ]] && cp -p -- "$old_file" "$rollback_tmp" && mv -f -- "$rollback_tmp" "$current_target"; then
                            :
                        else
                            [[ -z "$rollback_tmp" ]] || rm -f -- "$rollback_tmp"
                            rollback_failed=1
                            echo -e "${RED}[回滚失败]${PLAIN} 无法恢复：${current_target}" >&2
                        fi
                    else
                        rollback_failed=1
                        echo -e "${RED}[回滚失败]${PLAIN} 备份文件缺失：${old_file}" >&2
                    fi
                else
                    if [[ -L "$current_target" ]]; then
                        rollback_failed=1
                        echo -e "${RED}[回滚失败]${PLAIN} 目标意外变为符号链接，未删除：${current_target}" >&2
                    elif [[ -e "$current_target" ]] && ! rm -f -- "$current_target"; then
                        rollback_failed=1
                        echo -e "${RED}[回滚失败]${PLAIN} 无法移除新文件：${current_target}" >&2
                    fi
                fi
            done
            if (( rollback_failed == 0 )); then
                echo -e "${GREEN}[回滚完成]${PLAIN} 已恢复更新前的程序文件。配置、节点数据和 sing-box 服务未被更新流程修改。" >&2
                log_action "[更新回滚] 已恢复更新前的程序文件。"
                # Keep the old-version snapshot after a rollback for manual recovery/auditing.
                (( backup_has_old == 1 )) && keep_backup=1
            fi
        fi

        for candidate in "${candidate_paths[@]:-}"; do
            [[ -n "$candidate" && ( -e "$candidate" || -L "$candidate" ) ]] && rm -f -- "$candidate" || true
        done
        [[ -z "$temp" ]] || rm -rf -- "$temp"

        if [[ -n "$backup_dir" && -d "$backup_dir" ]]; then
            if (( keep_backup == 0 && backup_has_old == 0 )); then
                rm -rf -- "$backup_dir" || true
            elif (( keep_backup == 0 && transaction_ok == 0 && commit_started == 0 )); then
                rm -rf -- "$backup_dir" || true
            fi
        fi
        if (( rollback_failed == 1 )); then
            echo -e "${RED}[严重]${PLAIN} 自动回滚未能完整完成。旧文件备份保留在：${backup_dir}" >&2
            echo -e "${YELLOW}[建议]${PLAIN} 不要删除该备份目录；请通过 VPS 控制台检查磁盘/文件权限后恢复。" >&2
            log_action "[严重] 自动回滚未能完整完成，备份目录=${backup_dir}"
        elif (( transaction_ok == 1 && backup_has_old == 1 )); then
            echo -e "${BLUE}[备份]${PLAIN} 更新前程序文件备份：${backup_dir}"
        fi
        exit "$rc"
    }
    trap 'cleanup_sync' EXIT

    command -v flock >/dev/null 2>&1 || { echo -e "${RED}[错误]${PLAIN} 缺少 flock（util-linux），无法安全同步。"; return 1; }
    [[ ! -L "${LOCAL_ROOT}/.protocol-sync.lock" ]] || { echo -e "${RED}[错误]${PLAIN} 更新锁文件不能是符号链接。"; return 1; }
    touch "${LOCAL_ROOT}/.protocol-sync.lock" || return 1
    chmod 600 "${LOCAL_ROOT}/.protocol-sync.lock" || return 1
    exec 9>>"${LOCAL_ROOT}/.protocol-sync.lock"
    flock -n 9 || { echo -e "${YELLOW}[提示]${PLAIN} 程序同步正在进行，本次退出。"; return 1; }
    local temp_root="${LOCAL_ROOT}/.tmp"
    [[ ! -L "$temp_root" && ( ! -e "$temp_root" || -d "$temp_root" ) ]] || { echo -e "${RED}[错误]${PLAIN} 更新临时目录路径不安全：${temp_root}"; return 1; }
    mkdir -p "$temp_root" || return 1
    chmod 700 "$temp_root" || return 1
    local temp_free_kb
    temp_free_kb=$(df -Pk -- "$temp_root" 2>/dev/null | awk 'NR==2 {print $4; exit}') || temp_free_kb=""
    [[ "$temp_free_kb" =~ ^[0-9]+$ ]] || { echo -e "${RED}[错误]${PLAIN} 无法检测更新临时目录剩余空间；未下载或替换文件。"; return 1; }
    (( temp_free_kb >= 65536 )) || { echo -e "${RED}[磁盘空间不足]${PLAIN} 更新临时目录至少需要 64 MiB 可用空间；未下载或替换文件。"; return 1; }
    temp=$(mktemp -d "${temp_root}/easy-vpn-sync.XXXXXX") || {
        echo -e "${RED}[错误]${PLAIN} 无法创建更新临时目录；没有更改当前安装。" >&2
        return 1
    }

    if local_bundle_available "$source_dir" && [[ "${2:-local}" != remote ]]; then
        source_dir=$(cd -- "$source_dir" && pwd -P)
        echo -e "${BLUE}[同步]${PLAIN} 使用本地 Easy VPN 完整包。"
        for file in "${rels[@]}"; do
            [[ -f "${source_dir}/${file}" && ! -L "${source_dir}/${file}" ]] || { echo -e "${RED}[错误]${PLAIN} 缺少或不安全的项目文件：${file}"; return 1; }
            mkdir -p "${temp}/$(dirname "$file")"
            cp -p -- "${source_dir}/${file}" "${temp}/${file}"
        done
    else
        require_verifiable_remote_source || return 1
        base=$(raw_base_url)
        direct_base=$(raw_direct_base_url)
        if [[ "${EASY_VPN_GITHUB_SOURCE_MODE:-direct}" == "china" ]]; then
            echo -e "${BLUE}[同步]${PLAIN} 优先通过国内加速源同步 Easy VPN 文件；单文件失败时将尝试官方直连源。"
        else
            echo -e "${BLUE}[同步]${PLAIN} 从 GitHub 分支 ${EASY_VPN_BRANCH} 下载程序与协议文件。"
        fi
        for file in "${rels[@]}"; do
            mkdir -p "${temp}/$(dirname "$file")"
            if ! download_bundle_file "$base" "$direct_base" "$file" "${temp}/${file}"; then
                rm -f -- "${temp}/${file}"
                echo -e "${RED}[错误]${PLAIN} 下载失败：${file}；官方源/加速源均不可用，当前文件未被替换。"; return 1;
            fi
        done
        if [[ -n "$EASY_VPN_RELEASE_PUBKEY" ]]; then
            for file in SHA256SUMS SHA256SUMS.sig; do
                if ! download_bundle_file "$base" "$direct_base" "$file" "${temp}/${file}"; then
                    rm -f -- "${temp}/${file}"
                    echo -e "${RED}[错误]${PLAIN} 下载发布签名文件失败：${file}；当前文件未被替换。"; return 1;
                fi
            done
            verify_bundle_signature "$temp" "${rels[@]}" || {
                echo -e "${RED}[签名校验失败]${PLAIN} 远端文件与发布签名不一致（可能被代理/镜像篡改，或维护者尚未重新签名发布）；已拒绝同步，当前安装保持不变。"; return 1;
            }
            echo -e "${GREEN}[签名校验]${PLAIN} 发布签名与全部文件哈希校验通过。"
        else
            if [[ "${EASY_VPN_GITHUB_SOURCE_MODE:-direct}" == "china" ]]; then
                echo -e "${YELLOW}[警告]${PLAIN} 本发布包未启用签名校验，且文件来自第三方加速源，内容真实性无法验证。"
            else
                echo -e "${YELLOW}[提示]${PLAIN} 本发布包未启用签名校验，仅依赖 GitHub 官方 HTTPS 源保证来源。"
            fi
        fi
    fi

    for file in "${temp}/install.sh" "${temp}/lib/common.sh" "${temp}/modules/protocol.sh"; do
        bash -n "$file" || { echo -e "${RED}[错误]${PLAIN} Bash 语法检查失败：${file}；当前安装保持不变。"; return 1; }
    done
    remote_version=$(grep -m1 '^CURRENT_VERSION=' "${temp}/install.sh" | cut -d'"' -f2)
    [[ "$remote_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
        echo -e "${RED}[错误]${PLAIN} Easy VPN 版本号无效：${remote_version}；当前安装保持不变。"; return 1;
    }
    bundle_version=$(tr -d '[:space:]' < "${temp}/VERSION")
    [[ "$bundle_version" == "$remote_version" ]] || {
        echo -e "${RED}[错误]${PLAIN} VERSION（${bundle_version}）与 install.sh（${remote_version}）版本不一致，拒绝同步。"; return 1;
    }
    jq -e '(.schema_version | type == "number") and (.tool_version | type == "string") and (.protocols | type == "array") and all(.protocols[]; (.id | type == "string") and (.name | type == "string") and (.adapter_version | type == "number") and (.status | type == "string") and (.implemented | type == "boolean"))' \
        "${temp}/protocol_catalog.json" >/dev/null || { echo -e "${RED}[错误]${PLAIN} 协议清单 JSON / 字段格式无效，当前安装保持不变。"; return 1; }
    catalog_version=$(jq -r '.tool_version' "${temp}/protocol_catalog.json")
    [[ "$catalog_version" == "$remote_version" ]] || {
        echo -e "${RED}[错误]${PLAIN} 协议清单版本（${catalog_version}）与程序版本（${remote_version}）不一致，拒绝同步。"; return 1;
    }

    # Never let a branch rollback or stale mirror replace a numerically newer installation.
    if [[ -e "${LOCAL_ROOT}/VERSION" || -L "${LOCAL_ROOT}/VERSION" ]]; then
        [[ -f "${LOCAL_ROOT}/VERSION" && ! -L "${LOCAL_ROOT}/VERSION" ]] || {
            echo -e "${RED}[错误]${PLAIN} 本地 VERSION 不是安全的普通文件，拒绝更新/重装。"; return 1;
        }
        local installed_version
        installed_version=$(tr -d '[:space:]' < "${LOCAL_ROOT}/VERSION")
        [[ "$installed_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
            echo -e "${RED}[错误]${PLAIN} 本地版本号无效（${installed_version}），无法安全判断是否降级；拒绝更新。"; return 1;
        }
        if easy_vpn_version_gt "$installed_version" "$bundle_version"; then
            echo -e "${RED}[版本保护]${PLAIN} 远端版本 v${bundle_version} 低于本地 v${installed_version}，拒绝降级。"; return 1;
        fi
    fi

    # Refuse unsafe file types and symlinked parent directories before preparing any replacements.
    for target in "$LOCAL_ROOT" "$LOCAL_LIB" "$LOCAL_MODULES"; do
        [[ ! -L "$target" && ( ! -e "$target" || -d "$target" ) ]] || {
            echo -e "${RED}[错误]${PLAIN} 安装目录不是安全的普通目录：${target}"; return 1;
        }
    done
    mkdir -p "$LOCAL_ROOT" "$LOCAL_LIB" "$LOCAL_MODULES"
    for file in "${rels[@]}"; do
        target="${LOCAL_ROOT}/${file}"
        [[ ! -L "$target" && ( ! -e "$target" || -f "$target" ) ]] || {
            echo -e "${RED}[错误]${PLAIN} 更新目标不是安全的普通文件：${target}"; return 1;
        }
        new_bytes=$((new_bytes + $(stat -c '%s' -- "${temp}/${file}")))
        if [[ -f "$target" ]]; then
            had_old+=(1)
            old_bytes=$((old_bytes + $(stat -c '%s' -- "$target")))
            backup_has_old=1
        else
            had_old+=(0)
        fi
        target_paths+=("$target")
    done

    root_dev=$(stat -c '%d' -- "$LOCAL_ROOT")
    log_dev=$(stat -c '%d' -- "$LOG_DIR")
    root_free_kb=$(df -Pk -- "$LOCAL_ROOT" | awk 'NR==2 && $4 ~ /^[0-9]+$/ {print $4; exit}')
    log_free_kb=$(df -Pk -- "$LOG_DIR" | awk 'NR==2 && $4 ~ /^[0-9]+$/ {print $4; exit}')
    [[ "$root_free_kb" =~ ^[0-9]+$ && "$log_free_kb" =~ ^[0-9]+$ ]] || { echo -e "${RED}[错误]${PLAIN} 无法可靠读取更新目录剩余空间；为安全起见取消更新。"; return 1; }
    new_bytes_kb=$(((new_bytes + 1023) / 1024))
    old_bytes_kb=$(((old_bytes + 1023) / 1024))
    margin_kb=$(((margin_bytes + 1023) / 1024))
    if [[ "$root_dev" == "$log_dev" ]]; then
        (( root_free_kb >= new_bytes_kb + old_bytes_kb + margin_kb )) || {
            echo -e "${RED}[磁盘空间不足]${PLAIN} 更新所需临时文件和备份空间不足；未替换任何程序文件。"; return 1;
        }
    else
        (( root_free_kb >= new_bytes_kb + margin_kb && log_free_kb >= old_bytes_kb + margin_kb )) || {
            echo -e "${RED}[磁盘空间不足]${PLAIN} 安装目录或备份目录空间不足；未替换任何程序文件。"; return 1;
        }
    fi

    mkdir -p "${LOG_DIR}/backups"
    chmod 700 "${LOG_DIR}/backups" 2>/dev/null || true
    backup_dir=$(mktemp -d "${LOG_DIR}/backups/easy-vpn-update.XXXXXX") || {
        echo -e "${RED}[错误]${PLAIN} 无法创建更新前备份，已取消。"; return 1;
    }
    chmod 700 "$backup_dir"
    for idx in "${!rels[@]}"; do
        file="${rels[$idx]}"
        target="${target_paths[$idx]}"
        if [[ "${had_old[$idx]}" == 1 ]]; then
            mkdir -p "${backup_dir}/original/$(dirname "$file")"
            cp -p -- "$target" "${backup_dir}/original/${file}" || {
                echo -e "${RED}[错误]${PLAIN} 备份现有文件失败：${target}；未修改任何程序文件。"; return 1;
            }
        fi
        mode=755
        [[ "$file" == protocol_catalog.json || "$file" == VERSION ]] && mode=644
        candidate=$(mktemp "${target%/*}/.easy-vpn-new.XXXXXX") || {
            echo -e "${RED}[错误]${PLAIN} 无法在目标目录创建临时文件：${target%/*}；未修改任何程序文件。"; return 1;
        }
        candidate_paths+=("$candidate")
        install -m "$mode" -- "${temp}/${file}" "$candidate" || {
            echo -e "${RED}[错误]${PLAIN} 准备更新文件失败：${file}；未修改任何程序文件。"; return 1;
        }
    done

    echo -e "${BLUE}[安全检查]${PLAIN} 下载、版本、JSON、Bash 语法和磁盘空间检查通过；已准备更新前备份。"
    commit_started=1
    for idx in "${!rels[@]}"; do
        target="${target_paths[$idx]}"
        candidate="${candidate_paths[$idx]}"
        if mv -f -- "$candidate" "$target"; then
            changed_indices+=("$idx")
        else
            echo -e "${RED}[错误]${PLAIN} 替换文件失败：${target}。将恢复所有已经替换的文件。"
            return 1
        fi
    done

    # Health-check the installed files in an isolated shell before calling the sync successful.
    if ! (
        set -Eeuo pipefail
        bash -n "${LOCAL_ROOT}/install.sh"
        bash -n "${LOCAL_LIB}/common.sh"
        bash -n "${LOCAL_MODULES}/protocol.sh"
        jq -e --arg version "$bundle_version" '.tool_version == $version and all(.protocols[]; (.id | type == "string") and (.name | type == "string") and (.adapter_version | type == "number") and (.status | type == "string") and (.implemented | type == "boolean"))' \
            "${LOCAL_ROOT}/protocol_catalog.json" >/dev/null
        EASY_VPN_ROOT="$LOCAL_ROOT" EASY_VPN_ETC="$LOG_DIR" \
        EASY_VPN_STATE="${LOG_DIR}/state" EASY_VPN_BACKUPS="${LOG_DIR}/backups" \
        EASY_VPN_LOG="$LOG_FILE" bash -c '
            set -Eeuo pipefail
            root="$1"
            source "$root/lib/common.sh"
            source "$root/modules/protocol.sh"
            protocol_catalog_is_valid "$root/protocol_catalog.json"
            declare -F protocol_menu >/dev/null
            declare -F show_easy_vpn_summary >/dev/null
            declare -F protocol_update_check >/dev/null
            TERM=xterm protocol_menu </dev/null >/dev/null 2>&1
        ' _ "$LOCAL_ROOT"
    ); then
        echo -e "${RED}[健康检查失败]${PLAIN} 新版文件未通过加载/入口检查，正在自动回滚。"
        return 1
    fi

    transaction_ok=1
    log_action "[Easy VPN] 安全同步完成，版本=${remote_version}，分支=${EASY_VPN_BRANCH}，重装/更新均保留配置与节点数据"
    echo -e "${GREEN}[同步成功]${PLAIN} Easy VPN 程序与协议模块已更新至 v${remote_version}，健康检查通过。"
    # Do not delete unrelated legacy files on a shared install path. Fresh Easy VPN installs only include this project's files.
)
install_shortcut() {
    local tmp
    if [[ -e "$SHORTCUT" && ! -f "$SHORTCUT" ]]; then
        echo -e "${RED}[错误]${PLAIN} ${SHORTCUT} 存在且不是普通文件，拒绝覆盖。"; return 1
    fi
    if [[ -f "$SHORTCUT" ]] && ! grep -Fq "${LOCAL_ROOT}/install.sh" "$SHORTCUT"; then
        mkdir -p "${LOG_DIR}/backups/shortcut"
        [[ -f "${LOG_DIR}/backups/shortcut/original" ]] || cp -a -- "$SHORTCUT" "${LOG_DIR}/backups/shortcut/original"
        touch "${LOG_DIR}/backups/shortcut/present"
    fi
    tmp=$(mktemp) || { echo -e "${RED}[错误]${PLAIN} 无法创建快捷命令临时文件。" >&2; return 1; }
    if ! printf '#!/usr/bin/env bash\nexec %q "$@"\n' "${LOCAL_ROOT}/install.sh" > "$tmp"; then
        rm -f -- "$tmp"
        echo -e "${RED}[错误]${PLAIN} 无法写入快捷命令临时文件。" >&2
        return 1
    fi
    local shortcut_dir="${SHORTCUT%/*}"
    [[ -n "$shortcut_dir" ]] || shortcut_dir="/"
    if ! mkdir -p -- "$shortcut_dir"; then
        rm -f -- "$tmp"
        echo -e "${RED}[错误]${PLAIN} 无法创建快捷命令目录：${shortcut_dir}" >&2
        return 1
    fi
    if ! install -m 755 -- "$tmp" "$SHORTCUT"; then
        rm -f -- "$tmp"
        echo -e "${RED}[错误]${PLAIN} 无法安装快捷命令：${SHORTCUT}" >&2
        return 1
    fi
    rm -f -- "$tmp"

    # Remove the previous Easy VPN shortcut only when it is our own regular wrapper.
    if [[ "$LEGACY_SHORTCUT" != "$SHORTCUT" && -f "$LEGACY_SHORTCUT" && ! -L "$LEGACY_SHORTCUT" ]] &&
       grep -Fq "${LOCAL_ROOT}/install.sh" "$LEGACY_SHORTCUT"; then
        rm -f -- "$LEGACY_SHORTCUT"
    fi
}

install_uppercase_shortcut() {
    local tmp shortcut_dir
    [[ "$UPPERCASE_SHORTCUT" != "$SHORTCUT" ]] || return 0
    if [[ -L "$UPPERCASE_SHORTCUT" || ( -e "$UPPERCASE_SHORTCUT" && ! -f "$UPPERCASE_SHORTCUT" ) ]]; then
        echo -e "${RED}[错误]${PLAIN} ${UPPERCASE_SHORTCUT} 存在且不是安全的普通文件，拒绝覆盖。"; return 1
    fi
    if [[ -f "$UPPERCASE_SHORTCUT" ]] && ! grep -Fq "${LOCAL_ROOT}/install.sh" "$UPPERCASE_SHORTCUT"; then
        mkdir -p "${LOG_DIR}/backups/shortcut-uppercase"
        [[ -f "${LOG_DIR}/backups/shortcut-uppercase/original" ]] || cp -a -- "$UPPERCASE_SHORTCUT" "${LOG_DIR}/backups/shortcut-uppercase/original"
        touch "${LOG_DIR}/backups/shortcut-uppercase/present"
    fi
    tmp=$(mktemp) || { echo -e "${RED}[错误]${PLAIN} 无法创建大写快捷命令临时文件。" >&2; return 1; }
    if ! printf '#!/usr/bin/env bash\nexec %q "$@"\n' "${LOCAL_ROOT}/install.sh" > "$tmp"; then
        rm -f -- "$tmp"
        echo -e "${RED}[错误]${PLAIN} 无法写入大写快捷命令临时文件。" >&2
        return 1
    fi
    shortcut_dir="${UPPERCASE_SHORTCUT%/*}"
    [[ -n "$shortcut_dir" ]] || shortcut_dir="/"
    if ! mkdir -p -- "$shortcut_dir"; then
        rm -f -- "$tmp"
        echo -e "${RED}[错误]${PLAIN} 无法创建快捷命令目录：${shortcut_dir}" >&2
        return 1
    fi
    if ! install -m 755 -- "$tmp" "$UPPERCASE_SHORTCUT"; then
        rm -f -- "$tmp"
        echo -e "${RED}[错误]${PLAIN} 无法安装大写快捷命令：${UPPERCASE_SHORTCUT}" >&2
        return 1
    fi
    rm -f -- "$tmp"
}

install_dependencies
if [[ "${1:-}" == "--update-return" ]]; then
    sync_bundle "" remote || exit $?
    install_shortcut
    install_uppercase_shortcut
    exit $?
fi

current_script_path=""
if [[ -n "$SCRIPT_SOURCE" ]]; then
    current_script_path=$(readlink -f -- "$SCRIPT_SOURCE" 2>/dev/null || printf '%s' "$SCRIPT_SOURCE")
fi
local_install_path=$(readlink -m -- "${LOCAL_ROOT}/install.sh" 2>/dev/null || printf '%s' "${LOCAL_ROOT}/install.sh")
# An empty source path means the bootstrap came from stdin; force remote sync
# into the durable install tree before re-executing the installed installer.
if [[ -z "$current_script_path" || "$current_script_path" != "$local_install_path" ]]; then
    sync_bundle "$SOURCE_DIR"
    exec "${LOCAL_ROOT}/install.sh" "$@"
fi

export EASY_VPN_ROOT="$LOCAL_ROOT"
export EASY_VPN_ETC="$LOG_DIR"
source "${LOCAL_LIB}/common.sh"
source "${LOCAL_MODULES}/protocol.sh"
install_shortcut
install_uppercase_shortcut

# Dispatch non-interactive actions from the actual public entrypoint. The shortcut
# forwards all arguments here, and the bootstrap installer preserves them on exec.
dispatch_cli_command() {
    case "${1:-}" in
        --pipeline-reality)
            export EASY_VPN_PIPELINE=1
            deploy_vless_reality pipeline
            return $?
            ;;
        --help|-h)
            cat <<'USAGE'
Easy VPN usage:
  VPN                       Open the interactive menu (uppercase alias)
  vpn                       Open the interactive menu (lowercase alias)
  VPN --pipeline-reality    Deploy VLESS + Reality in pipeline mode

Pipeline mode can use EASY_VPN_SERVER_IP to explicitly provide the public
server address if automatic public-IP detection is unavailable, for example:
  EASY_VPN_SERVER_IP=203.0.113.10 VPN --pipeline-reality
USAGE
            return 0
            ;;
        *) return 64 ;;
    esac
}

if (( $# > 0 )); then
    if dispatch_cli_command "$@"; then
        exit 0
    else
        dispatch_rc=$?
        # Unknown flags retain the normal menu behavior; recognized action
        # failures return their own nonzero status to automation callers.
        [[ "$dispatch_rc" -eq 64 ]] || exit "$dispatch_rc"
    fi
fi

# curl | sudo bash leaves stdin at EOF after the downloaded installer has been read.
# Restore the controlling terminal for the interactive menu when one exists. In a
# non-interactive session (e.g. automation without a controlling TTY), finish the
# installation successfully and tell the user to start the menu later with `VPN` or `vpn`.
if [[ ! -t 0 ]]; then
    tty_device="${EASY_VPN_TTY_DEVICE:-/dev/tty}"
    if { exec 3<"$tty_device"; } 2>/dev/null; then
        exec 0<&3
        exec 3<&-
    else
        echo -e "${GREEN}[完成]${PLAIN} Easy VPN 已安装；当前会话没有可交互终端。请在终端中输入 ${CYAN}VPN${PLAIN}（或 ${CYAN}vpn${PLAIN}）打开菜单。"
        exit 0
    fi
fi
protocol_menu
