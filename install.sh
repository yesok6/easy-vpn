#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

CURRENT_VERSION="1.0.11"
GITHUB_USER="${EASY_VPN_GITHUB_USER:-yesok6}"
GITHUB_REPO="${EASY_VPN_GITHUB_REPO:-easy-vpn}"
export EASY_VPN_GITHUB_USER="$GITHUB_USER" EASY_VPN_GITHUB_REPO="$GITHUB_REPO"
EASY_VPN_BRANCH="${EASY_VPN_BRANCH:-main}"
export EASY_VPN_BRANCH
LOCAL_ROOT="${EASY_VPN_ROOT:-/opt/easy-vpn}"
LOCAL_MODULES="${LOCAL_ROOT}/modules"
LOCAL_LIB="${LOCAL_ROOT}/lib"
LOG_DIR="${EASY_VPN_ETC:-/etc/easy-vpn}"
LOG_FILE="${LOG_DIR}/install.log"
SHORTCUT="${EASY_VPN_SHORTCUT:-/usr/local/bin/vpn}"
LEGACY_SHORTCUT="${EASY_VPN_LEGACY_SHORTCUT:-${SHORTCUT%/*}/easy-vpn}"
SOURCE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P)" || SOURCE_DIR=""

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

on_error() {
    local rc=$?
    echo -e "${RED}[错误]${PLAIN} 操作失败（退出码 ${rc}，位置 ${BASH_SOURCE[1]:-${BASH_SOURCE[0]}}:${BASH_LINENO[0]:-0}）。"
    echo -e "${YELLOW}[提示]${PLAIN} 详细日志：${LOG_FILE}"
    log_action "[失败] exit=${rc}"
    return "$rc"
}
trap on_error ERR

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

raw_base_url() {
    printf 'https://raw.githubusercontent.com/%s/%s/%s' "$GITHUB_USER" "$GITHUB_REPO" "$EASY_VPN_BRANCH"
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

sync_bundle() (
    set -Eeuo pipefail
    local source_dir="${1:-}" base temp remote_version bundle_version catalog_version file
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
        base=$(raw_base_url)
        echo -e "${BLUE}[同步]${PLAIN} 从 GitHub 分支 ${EASY_VPN_BRANCH} 下载程序与协议文件。"
        for file in "${rels[@]}"; do
            mkdir -p "${temp}/$(dirname "$file")"
            curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
                --connect-timeout 10 --max-time 120 --retry 2 \
                -o "${temp}/${file}" "${base}/${file}?t=$(date +%s)-${RANDOM}${RANDOM}" || {
                echo -e "${RED}[错误]${PLAIN} 下载失败：${file}；当前文件未被替换，请检查网络和分支 ${EASY_VPN_BRANCH}。"; return 1;
            }
        done
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

install_dependencies
if [[ "${1:-}" == "--update-return" ]]; then
    sync_bundle "" remote || exit $?
    install_shortcut
    exit $?
fi

current_script_path=$(readlink -f -- "${BASH_SOURCE[0]}" 2>/dev/null || printf '%s' "${BASH_SOURCE[0]}")
local_install_path=$(readlink -m -- "${LOCAL_ROOT}/install.sh" 2>/dev/null || printf '%s' "${LOCAL_ROOT}/install.sh")
if [[ "$current_script_path" != "$local_install_path" ]]; then
    sync_bundle "$SOURCE_DIR"
    exec "${LOCAL_ROOT}/install.sh" "$@"
fi

export EASY_VPN_ROOT="$LOCAL_ROOT"
export EASY_VPN_ETC="$LOG_DIR"
source "${LOCAL_LIB}/common.sh"
source "${LOCAL_MODULES}/protocol.sh"
install_shortcut

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
  vpn                       Open the interactive menu
  vpn --pipeline-reality    Deploy VLESS + Reality in pipeline mode

Pipeline mode can use EASY_VPN_SERVER_IP to explicitly provide the public
server address if automatic public-IP detection is unavailable, for example:
  EASY_VPN_SERVER_IP=203.0.113.10 vpn --pipeline-reality
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
# installation successfully and tell the user to start the menu later with `vpn`.
if [[ ! -t 0 ]]; then
    tty_device="${EASY_VPN_TTY_DEVICE:-/dev/tty}"
    if { exec 3<"$tty_device"; } 2>/dev/null; then
        exec 0<&3
        exec 3<&-
    else
        echo -e "${GREEN}[完成]${PLAIN} Easy VPN 已安装；当前会话没有可交互终端。请在终端中运行 ${CYAN}vpn${PLAIN} 打开菜单。"
        exit 0
    fi
fi
protocol_menu
