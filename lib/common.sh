#!/usr/bin/env bash
umask 077

# Shared helpers for Easy VPN.
# This file is sourced by install.sh and all modules.

EASY_VPN_ROOT="${EASY_VPN_ROOT:-/opt/easy-vpn}"
EASY_VPN_ETC="${EASY_VPN_ETC:-/etc/easy-vpn}"
EASY_VPN_STATE="${EASY_VPN_STATE:-${EASY_VPN_ETC}/state}"
EASY_VPN_BACKUPS="${EASY_VPN_BACKUPS:-${EASY_VPN_ETC}/backups}"
EASY_VPN_LOG="${EASY_VPN_LOG:-${EASY_VPN_ETC}/install.log}"
# [可完全撤销] 工具专属 Swap；低内存且用户确认时按磁盘余量动态创建 256/512/768/1024 MiB，至少保留 1 GiB 根分区空间。
EASY_VPN_SWAP_PATH="${EASY_VPN_SWAP_PATH:-/var/lib/easy-vpn/swapfile}"
EASY_VPN_FSTAB_PATH="${EASY_VPN_FSTAB_PATH:-/etc/fstab}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
PLAIN='\033[0m'

mkdir -p "${EASY_VPN_ETC}" "${EASY_VPN_STATE}" "${EASY_VPN_BACKUPS}"
# The sing-box account needs traversal of /etc/easy-vpn, but other local users
# must not be able to enumerate it. Use root:easy-vpn 0710 once that group exists;
# otherwise keep the directory private until deployment creates the service account.
secure_easy_vpn_etc_dir() {
    if getent group easy-vpn >/dev/null 2>&1; then
        chown root:easy-vpn "${EASY_VPN_ETC}" 2>/dev/null || return 1
        chmod 0710 "${EASY_VPN_ETC}" 2>/dev/null || return 1
    else
        chmod 0700 "${EASY_VPN_ETC}" 2>/dev/null || return 1
    fi
    chmod 0700 "${EASY_VPN_STATE}" "${EASY_VPN_BACKUPS}" 2>/dev/null || return 1
}
secure_easy_vpn_etc_dir || true

die() {
    echo -e "${RED}[错误]${PLAIN} $*" >&2
    return 1
}

require_root() {
    if [[ ${EUID} -ne 0 ]]; then
        die "请使用 root 权限运行此脚本。"
        exit 1
    fi
}

log_action() {
    local action="${1:-}"
    mkdir -p "${EASY_VPN_ETC}"
    secure_easy_vpn_etc_dir || true
    ( umask 077; touch "${EASY_VPN_LOG}"; chmod 600 "${EASY_VPN_LOG}"; printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${action}" >> "${EASY_VPN_LOG}" )
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

get_mem_available_mb() {
    local value
    value=$(awk '/^MemAvailable:/ {printf "%d", $2/1024; found=1; exit} END {if (!found) exit 1}' /proc/meminfo 2>/dev/null) || value=""
    if [[ ! "$value" =~ ^[0-9]+$ ]]; then
        value=$(awk '/^MemFree:/ {free=$2} /^Buffers:/ {buffers=$2} /^Cached:/ {cached=$2} END { if (free+buffers+cached>0) printf "%d", (free+buffers+cached)/1024; else print 0 }' /proc/meminfo 2>/dev/null) || value=0
    fi
    [[ "$value" =~ ^[0-9]+$ ]] || value=0
    printf '%s\n' "$value"
}

get_root_free_mb() {
    local value
    value=$(df -Pm -P / 2>/dev/null | awk 'NR==2 {print $4; exit}') || value=""
    [[ "$value" =~ ^[0-9]+$ ]] || value=0
    printf '%s\n' "$value"
}

current_swap_mb() {
    awk 'NR > 1 {sum += $3} END {printf "%d\n", sum / 1024}' /proc/swaps 2>/dev/null
}

recommend_managed_swap_mb() {
    # [资源策略] 尽量增加可用 Swap，但始终至少保留 1 GiB 根分区空间。
    # [安全保留] 仅按 256 MiB 递增、单次最多补到 1 GiB；不覆盖用户已有 Swap。
    local disk_mb swap_mb room_mb target_mb
    disk_mb=$(get_root_free_mb)
    swap_mb=$(current_swap_mb)
    room_mb=$((disk_mb - 1024))
    target_mb=$((1024 - swap_mb))

    (( room_mb < 256 )) && { echo 0; return 0; }
    (( target_mb <= 0 )) && { echo 0; return 0; }
    (( target_mb > 1024 )) && target_mb=1024
    (( target_mb > room_mb )) && target_mb=$room_mb
    target_mb=$((target_mb / 256 * 256))
    (( target_mb >= 256 )) && echo "$target_mb" || echo 0
}

ensure_managed_swap() {
    # [可完全撤销] 仅创建 Easy VPN 自己管理的 Swap，不覆盖用户现有 Swap。
    # [说明] Swap 使用磁盘空间模拟额外内存，可缓解内存峰值时的 OOM 风险，但速度明显低于真实 RAM，不能替代内存。
    # [安全保留] 创建后必须至少保留 1 GiB 根分区空间；单次最多创建 1 GiB。
    local requested_mb="${1:-1024}" disk_mb swap_mb create_mb fstab_line fs_type swap_parent fstab_added=0
    (( requested_mb >= 256 )) || requested_mb=256
    (( requested_mb > 1024 )) && requested_mb=1024
    (( requested_mb % 256 != 0 )) && requested_mb=$((requested_mb / 256 * 256))

    disk_mb=$(get_root_free_mb)
    swap_mb=$(current_swap_mb)
    create_mb=$requested_mb
    if (( swap_mb >= 1024 )); then
        echo -e "${GREEN}[状态]${PLAIN} 当前已有 ${swap_mb} MiB Swap，无需重复创建。"
        return 0
    fi
    if (( create_mb > 1024 - swap_mb )); then
        create_mb=$((1024 - swap_mb))
    fi
    if (( create_mb > disk_mb - 1024 )); then
        create_mb=$((disk_mb - 1024))
    fi
    create_mb=$((create_mb / 256 * 256))
    if (( create_mb < 256 )); then
        echo -e "${YELLOW}[提示]${PLAIN} 当前根分区可用空间 ${disk_mb} MiB，不足以在保留 1 GiB 安全余量后再创建至少 256 MiB Swap，因此不创建。"
        return 2
    fi

    if [[ -e "$EASY_VPN_SWAP_PATH" || -L "$EASY_VPN_SWAP_PATH" ]]; then
        if [[ -L "$EASY_VPN_SWAP_PATH" || ! -f "$EASY_VPN_SWAP_PATH" ]] || ! is_owned "$EASY_VPN_SWAP_PATH"; then
            echo -e "${YELLOW}[提示]${PLAIN} ${EASY_VPN_SWAP_PATH} 已存在但不是可确认归属的普通文件，拒绝覆盖。"
            return 2
        fi
    elif grep -Fqx "$EASY_VPN_SWAP_PATH none swap sw 0 0" "$EASY_VPN_FSTAB_PATH" 2>/dev/null; then
        if is_owned "$EASY_VPN_SWAP_PATH" || [[ "$(state_get swap_created 2>/dev/null || true)" == 1 ]]; then
            remove_managed_swap_fstab_entry "$EASY_VPN_SWAP_PATH" "$EASY_VPN_FSTAB_PATH" || { echo -e "${RED}[错误]${PLAIN} 检测到本工具专属 Swap 的过期 fstab 项，但无法安全清理；未创建新的 Swap。" >&2; return 1; }
            unmark_owned "$EASY_VPN_SWAP_PATH"
            state_unset swap_created
            state_unset swap_size_mb
        else
            echo -e "${YELLOW}[安全保留]${PLAIN} ${EASY_VPN_FSTAB_PATH} 已有 Swap 项，但对应文件不存在且没有 Easy VPN 所有权记录；请先人工核对，未自动修改。" >&2
            return 1
        fi
    fi
    swap_parent="$(dirname "$EASY_VPN_SWAP_PATH")"
    if [[ "$EASY_VPN_SWAP_PATH" == /var/lib/easy-vpn/swapfile ]]; then
        [[ -d /var/lib && ! -L /var/lib && -w /var/lib ]] || { echo -e "${RED}[错误]${PLAIN} /var/lib 不存在、不可写或为符号链接，拒绝在不安全路径创建 Swap。" >&2; return 1; }
    fi
    [[ ! -L "$swap_parent" ]] || { echo -e "${RED}[错误]${PLAIN} Swap 父目录是符号链接：${swap_parent}"; return 1; }
    mkdir -p "$swap_parent" || return 1
    [[ ! -L "$swap_parent" && -d "$swap_parent" ]] || { echo -e "${RED}[错误]${PLAIN} Swap 父目录不安全：${swap_parent}"; return 1; }
    fs_type="$(findmnt -n -o FSTYPE -T "$swap_parent" 2>/dev/null | head -n1 || true)"
    case "$fs_type" in
        zfs)
            echo -e "${YELLOW}[安全保留]${PLAIN} 当前 Swap 路径位于 ZFS 文件系统；不自动创建普通 Swapfile（ZFS 文件 Swap 支持依赖具体实现），请使用系统/服务商支持的 ZVOL 或其他 Swap 方案。" >&2
            return 2 ;;
        btrfs)
            command_exists chattr || { echo -e "${RED}[错误]${PLAIN} Btrfs Swapfile 需要 chattr 设置 NOCOW 属性，但当前系统未提供 chattr。" >&2; return 1; } ;;
    esac

    # Existing tool-owned swap files may be left inactive after a reboot or a prior
    # cleanup attempt. Do not silently report success: verify/reactivate safely and
    # ensure its boot entry exists. Never delete an existing file on this path.
    if [[ -e "$EASY_VPN_SWAP_PATH" ]]; then
        fstab_line="$EASY_VPN_SWAP_PATH none swap sw 0 0"
        if managed_swap_is_active "$EASY_VPN_SWAP_PATH"; then
            if ! grep -Fqx "$fstab_line" "$EASY_VPN_FSTAB_PATH" 2>/dev/null; then
                append_managed_swap_fstab_entry "$EASY_VPN_SWAP_PATH" "$EASY_VPN_FSTAB_PATH" || {
                    echo -e "${RED}[错误]${PLAIN} Easy VPN Swap 仍处于活动状态，但无法安全补回 fstab 持久化项；保留活动 Swap 和所有权记录，请检查系统。" >&2
                    return 1
                }
            fi
            state_set swap_created 1 || return 1
            state_set swap_size_mb "$(du -m "$EASY_VPN_SWAP_PATH" 2>/dev/null | awk 'NR==1 && $1 ~ /^[0-9]+$/ {print $1}')" || true
            echo -e "${GREEN}[状态]${PLAIN} 已确认 Easy VPN Swap 文件存在且正在使用。"
            return 0
        fi
        if [[ "$fs_type" == btrfs ]]; then
            local existing_attrs
            existing_attrs=$(lsattr -d -- "$EASY_VPN_SWAP_PATH" 2>/dev/null | awk 'NR==1 {print $1}')
            [[ "$existing_attrs" == *C* ]] || {
                echo -e "${YELLOW}[安全保留]${PLAIN} 已有 Btrfs Swapfile 未能确认 NOCOW 属性；不会自动激活，避免触发内核拒绝或损坏风险。请备份确认后重新创建。" >&2
                return 2
            }
        fi
        fstab_added=0
        if ! grep -Fqx "$fstab_line" "$EASY_VPN_FSTAB_PATH" 2>/dev/null; then
            append_managed_swap_fstab_entry "$EASY_VPN_SWAP_PATH" "$EASY_VPN_FSTAB_PATH" || {
                echo -e "${RED}[错误]${PLAIN} 已有 Swap 文件但无法安全补回 fstab 项；未删除文件。" >&2
                return 1
            }
            fstab_added=1
        fi
        if ! swapon "$EASY_VPN_SWAP_PATH"; then
            if (( fstab_added )) && ! remove_managed_swap_fstab_entry "$EASY_VPN_SWAP_PATH" "$EASY_VPN_FSTAB_PATH"; then
                echo -e "${RED}[严重]${PLAIN} 已有 Swap 重新激活失败，且无法撤销新加入的 fstab 项；保留文件与所有权记录供人工恢复。" >&2
                return 1
            fi
            echo -e "${RED}[错误]${PLAIN} 已有 Easy VPN Swap 文件重新激活失败；文件及所有权记录已保留。" >&2
            return 1
        fi
        state_set swap_created 1 || { echo -e "${YELLOW}[警告]${PLAIN} Swap 已激活，但状态记录更新失败。" >&2; return 1; }
        state_set swap_size_mb "$(du -m "$EASY_VPN_SWAP_PATH" 2>/dev/null | awk 'NR==1 && $1 ~ /^[0-9]+$/ {print $1}')" || true
        echo -e "${GREEN}[完成]${PLAIN} 已重新激活 Easy VPN 管理的现有 Swap。"
        return 0
    fi

    if [[ ! -e "$EASY_VPN_SWAP_PATH" ]]; then
        if [[ "$fs_type" == btrfs ]]; then
            # Btrfs requires a newly-created empty file with NOCOW set before any allocation/write.
            : > "$EASY_VPN_SWAP_PATH" || return 1
            chattr +C "$EASY_VPN_SWAP_PATH" || { rm -f -- "$EASY_VPN_SWAP_PATH"; echo -e "${RED}[错误]${PLAIN} 无法为 Btrfs Swapfile 设置 NOCOW。" >&2; return 1; }
        fi
        if ! (fallocate -l "${create_mb}M" "$EASY_VPN_SWAP_PATH" 2>/dev/null || dd if=/dev/zero of="$EASY_VPN_SWAP_PATH" bs=1M count="$create_mb" status=none); then
            rm -f "$EASY_VPN_SWAP_PATH"
            echo -e "${RED}[错误]${PLAIN} ${create_mb} MiB Swap 文件创建失败。"
            return 1
        fi
        if ! chmod 600 "$EASY_VPN_SWAP_PATH" || ! mkswap "$EASY_VPN_SWAP_PATH" >/dev/null; then
            rm -f "$EASY_VPN_SWAP_PATH"
            echo -e "${RED}[错误]${PLAIN} Swap 初始化失败，已清理临时文件。"
            return 1
        fi
        fstab_line="$EASY_VPN_SWAP_PATH none swap sw 0 0"
        if ! grep -Fqx "$fstab_line" "$EASY_VPN_FSTAB_PATH"; then
            if ! append_managed_swap_fstab_entry "$EASY_VPN_SWAP_PATH" "$EASY_VPN_FSTAB_PATH"; then
                if managed_swap_is_active "$EASY_VPN_SWAP_PATH"; then
                    if ! swapoff "$EASY_VPN_SWAP_PATH" >/dev/null 2>&1 || managed_swap_is_active "$EASY_VPN_SWAP_PATH"; then
                        mark_owned "$EASY_VPN_SWAP_PATH" || true
                        state_set swap_created 1 || true
                        state_set swap_size_mb "$create_mb" || true
                        echo -e "${RED}[严重]${PLAIN} /etc/fstab 写入失败且 swapoff 也未能确认成功；已保留活动 Swap 文件和尽力写入的所有权记录，绝不删除活动文件。请立即检查。" >&2
                        return 1
                    fi
                fi
                rm -f -- "$EASY_VPN_SWAP_PATH"
                echo -e "${RED}[错误]${PLAIN} 无法安全写入 fstab，已停用并撤销本次创建的 Swap。"
                return 1
            fi
            fstab_added=1
        fi
        if ! mark_owned "$EASY_VPN_SWAP_PATH" || ! state_set swap_created 1 || ! state_set swap_size_mb "$create_mb"; then
            if managed_swap_is_active "$EASY_VPN_SWAP_PATH"; then
                if ! swapoff "$EASY_VPN_SWAP_PATH" >/dev/null 2>&1 || managed_swap_is_active "$EASY_VPN_SWAP_PATH"; then
                    mark_owned "$EASY_VPN_SWAP_PATH" || true
                    state_set swap_created 1 || true
                    state_set swap_size_mb "$create_mb" || true
                    echo -e "${RED}[严重]${PLAIN} Swap 状态记录失败且无法确认 swapoff；保留文件以避免删除活动 Swap。请检查状态目录。" >&2
                    return 1
                fi
            fi
            if (( fstab_added )) && ! remove_managed_swap_fstab_entry "$EASY_VPN_SWAP_PATH" "$EASY_VPN_FSTAB_PATH"; then
                mark_owned "$EASY_VPN_SWAP_PATH" || true
                state_set swap_created 1 || true
                state_set swap_size_mb "$create_mb" || true
                echo -e "${RED}[严重]${PLAIN} Swap 状态记录失败且无法撤销 fstab 项；保留文件和标记供人工恢复。" >&2
                return 1
            fi
            rm -f -- "$EASY_VPN_SWAP_PATH"
            unmark_owned "$EASY_VPN_SWAP_PATH"
            state_unset swap_created
            state_unset swap_size_mb
            echo -e "${RED}[错误]${PLAIN} Swap 状态记录失败，已回滚本次 Swap 创建。"
            return 1
        fi
        if ! swapon "$EASY_VPN_SWAP_PATH"; then
            if (( fstab_added )) && ! remove_managed_swap_fstab_entry "$EASY_VPN_SWAP_PATH" "$EASY_VPN_FSTAB_PATH"; then
                echo -e "${RED}[严重]${PLAIN} swapon 失败且无法撤销 fstab 项；保留文件和所有权记录，避免留下指向不存在文件的启动项。" >&2
                return 1
            fi
            rm -f -- "$EASY_VPN_SWAP_PATH"
            unmark_owned "$EASY_VPN_SWAP_PATH"
            state_unset swap_created
            state_unset swap_size_mb
            echo -e "${RED}[错误]${PLAIN} swapon 失败，已回滚 Swap 文件与本次 fstab 项。"
            return 1
        fi
        log_action "[可完全撤销] 创建 Easy VPN Swap：${create_mb} MiB，路径：${EASY_VPN_SWAP_PATH}"
        echo -e "${GREEN}[完成]${PLAIN} 已增加 ${create_mb} MiB 工具专属 Swap，用于缓解低内存峰值压力。"
    fi
    return 0
}

ensure_managed_swap_1g() {
    # [兼容入口] 保留原函数名；新逻辑会根据磁盘余量和现有 Swap 动态决定实际创建大小。
    local recommended_mb
    recommended_mb=$(recommend_managed_swap_mb)
    (( recommended_mb > 0 )) || return 2
    ensure_managed_swap "$recommended_mb"
}

require_commands() {
    local missing=()
    local cmd
    for cmd in "$@"; do
        command_exists "$cmd" || missing+=("$cmd")
    done
    if ((${#missing[@]})); then
        echo -e "${RED}[错误]${PLAIN} 缺少依赖: ${missing[*]}"
        return 1
    fi
}

make_temp_dir() {
    local prefix="${1:-easy-vpn}" base="${EASY_VPN_TMPDIR:-${EASY_VPN_ROOT}/.tmp}" required_mb="${2:-64}" available_kb
    [[ "$required_mb" =~ ^[0-9]+$ ]] || { echo "invalid temporary-directory space requirement: $required_mb" >&2; return 1; }
    required_mb=$((10#$required_mb))
    (( required_mb >= 1 && required_mb <= 4096 )) || { echo "temporary-directory space requirement out of bounds: $required_mb" >&2; return 1; }
    [[ ! -L "$base" && ( ! -e "$base" || -d "$base" ) ]] || { echo "unsafe Easy VPN temporary directory: $base" >&2; return 1; }
    mkdir -p -- "$base" || return 1
    chmod 700 -- "$base" || return 1
    available_kb=$(df -Pk -P -- "$base" 2>/dev/null | awk 'NR==2 {print $4; exit}') || available_kb=""
    [[ "$available_kb" =~ ^[0-9]+$ ]] || { echo "cannot determine temporary-directory free space: $base" >&2; return 1; }
    # Reserve more space for sing-box, where the downloaded archive and extracted
    # binary coexist briefly. Small metadata/rollback work keeps the 64 MiB default.
    (( available_kb >= required_mb * 1024 )) || { echo "insufficient disk space for temporary work in $base (need at least ${required_mb} MiB free)" >&2; return 1; }
    mktemp -d "${base%/}/${prefix}.XXXXXX"
}

download_https() {
    local url="${1:-}"
    local output="${2:-}"
    local part="" rc=0 attempt=1 max_attempts=3 resume_supported=1
    local -a curl_args=()

    [[ -n "$url" && -n "$output" ]] || {
        echo -e "${RED}[错误]${PLAIN} HTTPS 下载缺少 URL 或输出路径。" >&2
        return 2
    }
    [[ ! -d "$output" ]] || {
        echo -e "${RED}[错误]${PLAIN} HTTPS 下载目标是目录：${output}" >&2
        return 1
    }

    # Download into a private temporary file in the destination directory.
    # The final path is replaced only after curl confirms a complete response,
    # so a timeout cannot leave a truncated archive/script at the expected path.
    part=$(mktemp -- "${output}.part.XXXXXX") || {
        echo -e "${RED}[错误]${PLAIN} 无法创建 HTTPS 下载临时文件：${output}" >&2
        return 1
    }
    chmod 600 -- "$part" || { rm -f -- "$part"; return 1; }

    while (( attempt <= max_attempts )); do
        curl_args=(
            --fail --silent --show-error --location
            --proto '=https' --tlsv1.2
            --connect-timeout 15 --max-time 600
            --speed-limit 1024 --speed-time 120
            --output "$part"
        )
        # Resume from the already downloaded byte count after an interrupted
        # attempt. If the server rejects HTTP Range (curl exit 33), retry once
        # from byte zero instead of concatenating incompatible responses.
        if (( resume_supported )); then
            curl_args+=(--continue-at -)
        fi

        if curl "${curl_args[@]}" "$url"; then
            if [[ ! -s "$part" ]]; then
                echo -e "${RED}[错误]${PLAIN} 下载结果为空，拒绝保存：${url}" >&2
                rm -f -- "$part"
                return 1
            fi
            if ! mv -f -- "$part" "$output"; then
                echo -e "${RED}[错误]${PLAIN} 无法将下载文件保存到：${output}" >&2
                rm -f -- "$part"
                return 1
            fi
            return 0
        else
            rc=$?
        fi

        if (( rc == 33 && resume_supported )); then
            echo -e "${YELLOW}[提示]${PLAIN} 下载源不支持断点续传，将清空临时数据并尝试完整下载。" >&2
            resume_supported=0
            : > "$part" || { rm -f -- "$part"; return 1; }
        fi

        if (( attempt < max_attempts )); then
            if (( resume_supported )); then
                echo -e "${YELLOW}[提示]${PLAIN} 下载中断（curl 错误码 ${rc}），将从已接收的数据继续（${attempt}/${max_attempts}）。" >&2
            else
                echo -e "${YELLOW}[提示]${PLAIN} 下载失败（curl 错误码 ${rc}），将重新尝试完整下载（${attempt}/${max_attempts}）。" >&2
            fi
            sleep 2
        fi
        attempt=$((attempt + 1))
    done

    rm -f -- "$part"
    echo -e "${RED}[错误]${PLAIN} HTTPS 下载在 ${max_attempts} 次尝试后仍失败（curl 错误码 ${rc}）。" >&2
    return 1
}

download_shell_checked() {
    local url="$1"
    local output="$2"
    download_https "$url" "$output" || return 1
    bash -n "$output" || {
        echo -e "${RED}[错误]${PLAIN} 下载的脚本语法检查失败: ${url}"
        return 1
    }
    chmod 700 "$output"
}

state_key_file() {
    local key="$1"
    printf '%s/%s' "${EASY_VPN_STATE}" "${key}"
}

state_set() {
    local key="$1"
    local value="${2:-}"
    local file
    file=$(state_key_file "$key")
    printf '%s' "$value" > "$file"
    chmod 600 "$file"
}

state_get() {
    local key="$1"
    local file
    file=$(state_key_file "$key")
    [[ -f "$file" ]] && cat "$file"
}

state_exists() {
    [[ -f "$(state_key_file "$1")" ]]
}

state_unset() {
    rm -f "$(state_key_file "$1")"
}

backup_file_once() {
    local path="$1" key="$2" backup_dir backup_path marker temp_dir
    backup_dir="${EASY_VPN_BACKUPS}/${key}"
    backup_path="${backup_dir}/original"
    marker="${backup_dir}/present"

    [[ -n "$path" && -n "$key" && "$key" =~ ^[A-Za-z0-9_.-]+$ ]] || return 1
    [[ ! -L "$EASY_VPN_BACKUPS" && ( ! -e "$EASY_VPN_BACKUPS" || -d "$EASY_VPN_BACKUPS" ) ]] || return 1
    [[ ! -L "$backup_dir" && ( ! -e "$backup_dir" || -d "$backup_dir" ) ]] || return 1
    mkdir -p -- "$backup_dir" || return 1
    chmod 0700 "$backup_dir" || return 1

    if [[ -e "$backup_path" || -L "$backup_path" ]]; then
        [[ -f "$backup_path" && ! -L "$backup_path" && -f "$marker" && ! -L "$marker" ]] || return 1
        return 0
    fi
    if [[ -e "$backup_dir/missing" || -L "$backup_dir/missing" ]]; then
        [[ -f "$backup_dir/missing" && ! -L "$backup_dir/missing" ]] || return 1
        return 0
    fi

    if [[ -e "$path" || -L "$path" ]]; then
        [[ -f "$path" && ! -L "$path" ]] || { echo "refusing to back up non-regular/symlink file: $path" >&2; return 1; }
        temp_dir=$(mktemp -d "${backup_dir}/.backup.XXXXXX") || return 1
        if ! cp -p -- "$path" "${temp_dir}/original" || ! mv -- "${temp_dir}/original" "$backup_path"; then
            rm -rf -- "$temp_dir"
            return 1
        fi
        if ! (umask 077; : > "$marker"); then
            rm -f -- "$backup_path"
            rm -rf -- "$temp_dir"
            return 1
        fi
        rm -rf -- "$temp_dir"
    else
        (umask 077; : > "${backup_dir}/missing") || return 1
    fi
    chmod 0700 "$backup_dir" || return 1
}

restore_file_backup() {
    local path="$1" key="$2" backup_dir backup_path tmp_dir
    backup_dir="${EASY_VPN_BACKUPS}/${key}"
    backup_path="${backup_dir}/original"
    [[ ! -L "$backup_dir" && -d "$backup_dir" ]] || return 1

    if [[ -f "$backup_dir/present" && ! -L "$backup_dir/present" ]]; then
        [[ -f "$backup_path" && ! -L "$backup_path" ]] || return 1
        [[ ! -L "$path" && ( ! -e "$path" || -f "$path" ) ]] || { echo "refusing to restore over non-regular/symlink target: $path" >&2; return 1; }
        [[ ! -L "$(dirname -- "$path")" && -d "$(dirname -- "$path")" ]] || return 1
        tmp_dir=$(mktemp -d "$(dirname -- "$path")/.easy-vpn-restore.XXXXXX") || return 1
        if ! cp -p -- "$backup_path" "${tmp_dir}/restored" || ! mv -f -- "${tmp_dir}/restored" "$path"; then
            rm -rf -- "$tmp_dir"
            return 1
        fi
        rmdir "$tmp_dir" 2>/dev/null || true
        return 0
    fi

    if [[ -f "$backup_dir/missing" && ! -L "$backup_dir/missing" ]]; then
        if [[ -e "$path" || -L "$path" ]]; then
            [[ -f "$path" && ! -L "$path" ]] || return 1
            rm -f -- "$path" || return 1
        fi
        return 0
    fi
    return 1
}

mark_owned() {
    local path="$1"
    local id
    id=$(printf '%s' "$path" | sha256sum | awk '{print $1}')
    printf '%s' "$path" > "${EASY_VPN_STATE}/owned.${id}"
    chmod 600 "${EASY_VPN_STATE}/owned.${id}"
}

is_owned() {
    local path="$1"
    local id
    id=$(printf '%s' "$path" | sha256sum | awk '{print $1}')
    [[ -f "${EASY_VPN_STATE}/owned.${id}" ]] && [[ "$(cat "${EASY_VPN_STATE}/owned.${id}")" == "$path" ]]
}

unmark_owned() {
    local path="$1"
    local id
    id=$(printf '%s' "$path" | sha256sum | awk '{print $1}')
    rm -f "${EASY_VPN_STATE}/owned.${id}"
}

record_runtime_value() {
    local path="$1"
    local id
    id=$(printf '%s' "$path" | sha256sum | awk '{print $1}')
    local dir="${EASY_VPN_STATE}/runtime"
    mkdir -p "$dir"
    [[ -f "${dir}/${id}.path" || -f "${dir}/${id}.missing" ]] && return 0
    printf '%s' "$path" > "${dir}/${id}.path"
    if [[ -f "$path" ]]; then
        cat "$path" > "${dir}/${id}.value"
    else
        touch "${dir}/${id}.missing"
    fi
}

restore_runtime_values() {
    local dir="${EASY_VPN_STATE}/runtime"
    local path id restore_failed=0
    [[ -d "$dir" ]] || return 1
    for file in "$dir"/*.path; do
        [[ -f "$file" ]] || continue
        id="${file##*/}"
        id="${id%.path}"
        path=$(cat "$file")
        if [[ -f "${dir}/${id}.missing" ]]; then
            if ! rm -f "$path"; then
                restore_failed=1
            fi
        elif [[ -f "${dir}/${id}.value" ]]; then
            if ! cat "${dir}/${id}.value" > "$path" 2>/dev/null; then
                restore_failed=1
            fi
        fi
    done
    if (( restore_failed )); then
        echo -e "${YELLOW}[警告]${PLAIN} 部分运行时参数恢复失败，原始记录已保留。"
        return 1
    fi
    rm -rf "$dir"
    return 0
}

validate_port() {
    local port="${1:-}"
    [[ "$port" =~ ^[0-9]+$ ]] || return 1
    # Permit the standard web ports used by common deployments, but do not
    # generally expose every privileged port (<1024) to protocol listeners.
    [[ "$port" == 80 || "$port" == 443 ]] && return 0
    (( 10#$port >= 1024 && 10#$port <= 65535 ))
}

port_in_use() {
    local port="$1"
    local proto="${2:-both}"
    case "$proto" in
        tcp) ss -H -ltn 2>/dev/null | awk -v p=":${port}$" '$4 ~ p {found=1} END {exit found ? 0 : 1}' ;;
        udp) ss -H -lun 2>/dev/null | awk -v p=":${port}$" '$4 ~ p {found=1} END {exit found ? 0 : 1}' ;;
        both)
            port_in_use "$port" tcp || port_in_use "$port" udp
            ;;
        *) return 2 ;;
    esac
}

random_free_port() {
    local proto="${1:-tcp}"
    local attempts=0
    local port
    while ((attempts < 100)); do
        port=$((RANDOM % 50001 + 10000))
        if port_in_use "$port" "$proto"; then
            :
        else
            local rc=$?
            case "$rc" in
                1)
                    echo "$port"
                    return 0
                    ;;
                *)
                    echo -e "${RED}[错误]${PLAIN} 无法可靠检查随机端口 ${port}/${proto}，已停止选取。" >&2
                    return 1
                    ;;
            esac
        fi
        ((attempts += 1))
    done
    return 1
}

service_user_exists() {
    getent passwd easy-vpn >/dev/null 2>&1
}

service_group_exists() {
    getent group easy-vpn >/dev/null 2>&1
}

ensure_service_user() {
    local nologin
    if service_user_exists; then
        service_group_exists || {
            echo -e "${RED}[错误]${PLAIN} 已存在 easy-vpn 用户，但缺少对应组，拒绝自动创建以避免改变已有账号结构。"
            return 1
        }
        if [[ "$(state_get service_user_owned 2>/dev/null || true)" != "1" ]]; then
            state_set service_user_owned 0
        fi
        secure_easy_vpn_etc_dir || return 1
        if [[ ! -e /var/lib/easy-vpn ]]; then
            [[ -d /var/lib && ! -L /var/lib && -w /var/lib ]] || { echo -e "${RED}[错误]${PLAIN} /var/lib 不安全或不可写，无法准备服务工作目录。" >&2; return 1; }
            mkdir -m 0750 /var/lib/easy-vpn || return 1
            chown easy-vpn:easy-vpn /var/lib/easy-vpn || return 1
        elif [[ -L /var/lib/easy-vpn || ! -d /var/lib/easy-vpn ]]; then
            echo -e "${RED}[错误]${PLAIN} /var/lib/easy-vpn 不是安全目录，拒绝使用它作为服务工作目录。" >&2
            return 1
        fi
        chown easy-vpn:easy-vpn /var/lib/easy-vpn || return 1
        chmod 0750 /var/lib/easy-vpn || return 1
        return 0
    fi

    if ! service_group_exists; then
        groupadd --system easy-vpn
        state_set service_group_owned 1
    else
        state_set service_group_owned 0
    fi

    [[ -d /var/lib && ! -L /var/lib && -w /var/lib ]] || {
        echo -e "${RED}[错误]${PLAIN} /var/lib 不存在、不可写或为符号链接，无法安全创建 easy-vpn 服务账户家目录。" >&2
        return 1
    }
    [[ ! -L /var/lib/easy-vpn ]] || { echo -e "${RED}[错误]${PLAIN} /var/lib/easy-vpn 是符号链接，拒绝创建服务账户。" >&2; return 1; }
    nologin="$(command -v nologin 2>/dev/null || true)"
    [[ -n "$nologin" ]] || nologin="/usr/sbin/nologin"
    useradd --system --gid easy-vpn --home-dir /var/lib/easy-vpn --create-home --shell "$nologin" easy-vpn || return 1
    chown easy-vpn:easy-vpn /var/lib/easy-vpn || return 1
    chmod 0750 /var/lib/easy-vpn || return 1
    secure_easy_vpn_etc_dir || return 1
    state_set service_user_owned 1
}

managed_swap_is_active() {
    local path="${1:-$EASY_VPN_SWAP_PATH}"
    awk -v path="$path" 'NR > 1 && $1 == path { found=1 } END { exit(found ? 0 : 1) }' /proc/swaps 2>/dev/null
}

append_managed_swap_fstab_entry() (
    local path="$1" fstab="${2:-$EASY_VPN_FSTAB_PATH}" line tmp last_char lockfile
    lockfile="${EASY_VPN_STATE}/fstab-swap.lock"
    mkdir -p -- "$EASY_VPN_STATE" || return 1
    (umask 077; : >> "$lockfile") || return 1
    chmod 0600 "$lockfile" || return 1
    exec 9>>"$lockfile"
    command_exists flock && flock -x 9 || { echo "could not lock fstab swap edit" >&2; return 1; }
    [[ -f "$fstab" && ! -L "$fstab" ]] || { echo "refusing to edit missing/symlink fstab: $fstab" >&2; return 1; }
    line="$path none swap sw 0 0"
    if awk -v p="$path" '$1 == p && $3 == "swap" {found=1} END {exit(found ? 0 : 1)}' "$fstab"; then
        return 0
    fi
    backup_file_once "$fstab" managed_swap_fstab || return 1
    tmp=$(mktemp "$(dirname "$fstab")/.easy-vpn-fstab.XXXXXX") || return 1
    if ! cat -- "$fstab" > "$tmp"; then rm -f -- "$tmp"; return 1; fi
    last_char=$(tail -c 1 -- "$fstab" 2>/dev/null || true)
    [[ -z "$last_char" ]] || printf '\n' >> "$tmp"
    if ! printf '%s\n' "$line" >> "$tmp"; then rm -f -- "$tmp"; return 1; fi
    chmod --reference="$fstab" "$tmp" 2>/dev/null || { rm -f -- "$tmp"; return 1; }
    chown --reference="$fstab" "$tmp" 2>/dev/null || { rm -f -- "$tmp"; return 1; }
    mv -f -- "$tmp" "$fstab" || { rm -f -- "$tmp"; return 1; }
    command_exists restorecon && restorecon "$fstab" >/dev/null 2>&1 || true
)

remove_managed_swap_fstab_entry() (
    local path="$1" fstab="${2:-$EASY_VPN_FSTAB_PATH}" tmp lockfile
    lockfile="${EASY_VPN_STATE}/fstab-swap.lock"
    mkdir -p -- "$EASY_VPN_STATE" || return 1
    (umask 077; : >> "$lockfile") || return 1
    chmod 0600 "$lockfile" || return 1
    exec 9>>"$lockfile"
    command_exists flock && flock -x 9 || { echo "could not lock fstab swap edit" >&2; return 1; }
    [[ -f "$fstab" && ! -L "$fstab" ]] || return 0
    backup_file_once "$fstab" managed_swap_fstab || return 1
    tmp=$(mktemp "$(dirname "$fstab")/.easy-vpn-fstab.XXXXXX") || return 1
    if ! awk -v path="$path" '!(NF >= 3 && $1 == path && $3 == "swap") { print }' "$fstab" > "$tmp"; then
        rm -f -- "$tmp"
        return 1
    fi
    if cmp -s "$tmp" "$fstab"; then
        rm -f -- "$tmp"
        return 0
    fi
    chmod --reference="$fstab" "$tmp" 2>/dev/null || { rm -f -- "$tmp"; return 1; }
    chown --reference="$fstab" "$tmp" 2>/dev/null || { rm -f -- "$tmp"; return 1; }
    mv -f -- "$tmp" "$fstab" || { rm -f -- "$tmp"; return 1; }
    command_exists restorecon && restorecon "$fstab" >/dev/null 2>&1 || true
)

remove_managed_swap() {
    local path="$EASY_VPN_SWAP_PATH" owned=0
    is_owned "$path" && owned=1
    [[ "$(state_get swap_created 2>/dev/null || true)" == "1" ]] && owned=1

    if [[ -e "$path" || -L "$path" ]]; then
        if (( owned == 0 )) || [[ -L "$path" || ! -f "$path" ]]; then
            echo -e "${YELLOW}[安全保留]${PLAIN} Swap 路径存在但所有权/文件类型无法确认：${path}；不会停用或删除该文件，也不会删除其所在用户目录。" >&2
            return 1
        fi
    fi

    if managed_swap_is_active "$path"; then
        if (( owned == 0 )); then
            echo -e "${YELLOW}[安全保留]${PLAIN} 检测到活动 Swap ${path}，但没有 Easy VPN 所有权记录；拒绝停用它或删除服务用户。" >&2
            return 1
        fi
        if ! command_exists swapoff || ! swapoff "$path"; then
            echo -e "${RED}[错误]${PLAIN} 无法停用 Easy VPN 管理的活动 Swap：${path}。已保留服务用户及 Swap 文件，避免删除活动分页文件。" >&2
            return 1
        fi
        if managed_swap_is_active "$path"; then
            echo -e "${RED}[错误]${PLAIN} swapoff 返回成功，但 ${path} 仍显示为活动 Swap；已停止卸载以保护系统。" >&2
            return 1
        fi
    fi

    if (( owned == 0 )); then
        return 0
    fi
    remove_managed_swap_fstab_entry "$path" || {
        echo -e "${RED}[错误]${PLAIN} 无法安全更新 /etc/fstab，已保留 Swap 文件和所有权记录。" >&2
        return 1
    }
    if [[ -e "$path" || -L "$path" ]]; then
        rm -f -- "$path" || {
            echo -e "${RED}[错误]${PLAIN} 无法删除已停用的 Swap 文件：${path}；已保留所有权记录。" >&2
            return 1
        }
    fi
    unmark_owned "$path"
    state_unset swap_created
    state_unset swap_size_mb
    log_action "[已撤销] 移除 Easy VPN 管理的 Swap：${path}"
    return 0
}

remove_owned_service_user() {
    local user_owned=0 swap_owned=0
    [[ "$(state_get service_user_owned 2>/dev/null || true)" == "1" ]] && user_owned=1
    [[ "$(state_get swap_created 2>/dev/null || true)" == "1" ]] && swap_owned=1
    is_owned "$EASY_VPN_SWAP_PATH" && swap_owned=1

    # Remove a tool-owned swap even when the easy-vpn account pre-existed and
    # therefore is not itself owned by Easy VPN. If deleting an owned account,
    # also preflight any file at its swap path to avoid userdel removing an
    # unowned file or an active swap from that home directory.
    if (( swap_owned )) || { (( user_owned )) && service_user_exists; }; then
        remove_managed_swap || return 1
    fi
    if (( user_owned )) && service_user_exists; then
        if command_exists pgrep && pgrep -u easy-vpn >/dev/null 2>&1; then
            echo -e "${RED}[错误]${PLAIN} easy-vpn 账户仍有进程运行；为了避免误杀未知进程，未删除用户。请先检查 ps -u easy-vpn 并停止残留进程，再重试清理。" >&2
            return 1
        fi
        if ! userdel --remove easy-vpn 2>/dev/null; then
            if service_user_exists; then
                echo -e "${RED}[错误]${PLAIN} 删除 easy-vpn 系统用户失败；为避免遗留不明状态，保留账号和所有权记录。" >&2
                return 1
            fi
        fi
    fi
    if [[ "$(state_get service_group_owned 2>/dev/null || true)" == "1" ]] && service_group_exists; then
        groupdel easy-vpn 2>/dev/null || {
            echo -e "${YELLOW}[提示]${PLAIN} easy-vpn 组暂时无法删除；将保留组所有权记录以便重试。" >&2
            return 1
        }
    fi
    state_unset service_user_owned
    state_unset service_group_owned
}

firewall_backend() {
    if command_exists ufw && ufw status 2>/dev/null | grep -qw active; then
        echo ufw
        return 0
    fi
    if command_exists firewall-cmd && firewall-cmd --state 2>/dev/null | grep -qx running; then
        echo firewalld
        return 0
    fi
    echo none
}

# Record only firewall rules that this invocation newly created. Port-hopping
# deployments may provide one compact manifest so a large range does not create
# one ownership file per port; normal protocol installs keep the legacy per-port record.
firewall_record_new_rule() {
    local backend="$1" port="$2" proto="$3" manifest rule_file dir
    if [[ -n "${EASY_VPN_FIREWALL_OWNER_MANIFEST:-}" ]]; then
        manifest="$EASY_VPN_FIREWALL_OWNER_MANIFEST"
        [[ -f "$manifest" && ! -L "$manifest" ]] || return 1
        grep -Fxq "${backend}|${port}|${proto}" "$manifest" 2>/dev/null && return 0
        printf '%s|%s|%s\n' "$backend" "$port" "$proto" >> "$manifest" || return 1
        chmod 600 "$manifest" 2>/dev/null || return 1
        return 0
    fi
    dir="${EASY_VPN_STATE}/firewall"
    rule_file="${dir}/${proto}_${port}.rule"
    if [[ -e "$rule_file" || -L "$rule_file" ]]; then
        [[ -f "$rule_file" && ! -L "$rule_file" ]] || return 1
        [[ "$(sed -n '1p' "$rule_file")" == "$backend" && \
           "$(sed -n '2p' "$rule_file")" == "$port" && \
           "$(sed -n '3p' "$rule_file")" == "$proto" ]] || return 1
        return 0
    fi
    mkdir -p "$dir" || return 1
    (umask 077; printf '%s\n%s\n%s\n' "$backend" "$port" "$proto" > "$rule_file") || return 1
    chmod 600 "$rule_file" 2>/dev/null || return 1
}

firewall_allow() {
    local port="$1"
    local proto="$2"
    local backend batch_mode="${EASY_VPN_FIREWALL_BATCH:-0}" rule_file
    validate_port_any "$port" || return 1
    case "$proto" in tcp|udp) ;; *) return 1 ;; esac
    backend=$(firewall_backend)

    case "$backend" in
        ufw)
            if ! ufw status 2>/dev/null | grep -Eq "^[[:space:]]*${port}/${proto}([[:space:]]|$)"; then
                ufw allow "${port}/${proto}" >/dev/null || return 1
                if ! firewall_record_new_rule ufw "$port" "$proto"; then
                    ufw --force delete allow "${port}/${proto}" >/dev/null 2>&1 || true
                    return 1
                fi
            fi
            ;;
        firewalld)
            if firewall-cmd --query-port="${port}/${proto}" --permanent >/dev/null 2>&1; then
                return 0
            fi
            # [安全保留] 常见 HTTP/HTTPS/SSH service 已经放行时，不重复创建同端口规则；这些现有 service 不属于本工具所有。
            if [[ "$proto" == "tcp" && "$port" == "80" ]] && firewall-cmd --query-service=http --permanent >/dev/null 2>&1; then
                return 0
            fi
            if [[ "$proto" == "tcp" && "$port" == "443" ]] && firewall-cmd --query-service=https --permanent >/dev/null 2>&1; then
                return 0
            fi
            if [[ "$proto" == "tcp" && "$port" == "22" ]] && firewall-cmd --query-service=ssh --permanent >/dev/null 2>&1; then
                return 0
            fi
            firewall-cmd --permanent --add-port="${port}/${proto}" >/dev/null || return 1
            if ! firewall_record_new_rule firewalld "$port" "$proto"; then
                firewall-cmd --permanent --remove-port="${port}/${proto}" >/dev/null 2>&1 || true
                return 1
            fi
            if [[ "$batch_mode" != "1" ]]; then
                firewall-cmd --reload >/dev/null || return 1
            fi
            ;;
        none)
            echo -e "${YELLOW}[提示]${PLAIN} 当前未检测到已启用的 UFW/firewalld，未自动开启防火墙。"
            return 0
            ;;
    esac
}

# Validate the canonical port-range format used in Easy VPN state files: START-END.
validate_firewall_port_range() {
    local range="${1:-}" start end
    [[ "$range" =~ ^([0-9]{1,5})-([0-9]{1,5})$ ]] || return 1
    start="${BASH_REMATCH[1]}"; end="${BASH_REMATCH[2]}"
    (( 10#$start >= 1 && 10#$end <= 65535 && 10#$start < 10#$end ))
}

# Return success when a numeric rule specification overlaps a requested range.
# Supported spec forms are 1234/udp, 1200:1300/udp, 1200-1300/udp,
# and comma-separated ports/ranges as documented by the firewall frontend.
_firewall_port_spec_overlaps_range() {
    local spec="${1:-}" start="$2" end="$3" proto="$4" ports item low high
    [[ "$spec" == */"$proto" ]] || return 1
    ports="${spec%/$proto}"
    local -a parts=()
    IFS=',' read -r -a parts <<< "$ports"
    for item in "${parts[@]}"; do
        if [[ "$item" =~ ^([0-9]{1,5})$ ]]; then
            low="${BASH_REMATCH[1]}"; high="$low"
        elif [[ "$item" =~ ^([0-9]{1,5})[:-]([0-9]{1,5})$ ]]; then
            low="${BASH_REMATCH[1]}"; high="${BASH_REMATCH[2]}"
            (( 10#$low >= 1 && 10#$high <= 65535 && 10#$low <= 10#$high )) || continue
        else
            continue
        fi
        if (( 10#$low <= 10#$end && 10#$high >= 10#$start )); then
            return 0
        fi
    done
    return 1
}

# Inspect one firewall's explicitly configured port rules for a requested range.
# Return 0 if globally allowed rules already cover every port, 1 if there is no
# overlap, 2 if overlapping/conflicting rules make a new broad allow unsafe, 3 on
# inspection failure. A result of 0 means Easy VPN must not claim ownership.
_firewall_ufw_range_state() {
    local start="$1" end="$2" proto="$3" status_text line token action global
    local overlap=0 conflict=0 low high item port_spec row_exact
    local -a coverage=() pieces=()
    local p idx
    for ((p=start; p<=end; p++)); do coverage[$((p-start))]=0; done
    status_text=$(ufw status numbered 2>/dev/null) || return 3
    while IFS= read -r line; do
        action=""
        for token in $line; do
            case "$token" in ALLOW|DENY|REJECT|LIMIT) action="$token"; break ;; esac
        done
        [[ -n "$action" ]] || continue
        global=0
        [[ "$line" =~ (^|[[:space:]])Anywhere([[:space:]]|$) ]] && global=1
        # Restrict parsing to tokens that explicitly carry the requested protocol.
        for token in $line; do
            [[ "$token" == */"$proto" ]] || continue
            if ! _firewall_port_spec_overlaps_range "$token" "$start" "$end" "$proto"; then continue; fi
            overlap=1
            if [[ "$action" != ALLOW || "$global" != 1 ]]; then
                conflict=1
                continue
            fi
            port_spec="${token%/$proto}"
            IFS=',' read -r -a pieces <<< "$port_spec"
            for item in "${pieces[@]}"; do
                if [[ "$item" =~ ^([0-9]{1,5})$ ]]; then
                    low="${BASH_REMATCH[1]}"; high="$low"
                elif [[ "$item" =~ ^([0-9]{1,5})[:-]([0-9]{1,5})$ ]]; then
                    low="${BASH_REMATCH[1]}"; high="${BASH_REMATCH[2]}"
                else
                    continue
                fi
                (( 10#$low < 10#$start )) && low="$start"
                (( 10#$high > 10#$end )) && high="$end"
                for ((p=low; p<=high; p++)); do coverage[$((p-start))]=1; done
            done
        done
    done <<< "$status_text"
    (( conflict == 0 )) || return 2
    if (( overlap )); then
        for idx in "${!coverage[@]}"; do (( coverage[$idx] == 1 )) || return 2; done
        return 0
    fi
    return 1
}

_firewall_firewalld_range_state() {
    local start="$1" end="$2" proto="$3" list token ports overlap=0 low high item
    local -a coverage=() pieces=()
    local p idx
    for ((p=start; p<=end; p++)); do coverage[$((p-start))]=0; done
    list=$(firewall-cmd --permanent --list-ports 2>/dev/null) || return 3
    for token in $list; do
        [[ "$token" == */"$proto" ]] || continue
        _firewall_port_spec_overlaps_range "$token" "$start" "$end" "$proto" || continue
        overlap=1
        ports="${token%/$proto}"
        IFS=',' read -r -a pieces <<< "$ports"
        for item in "${pieces[@]}"; do
            if [[ "$item" =~ ^([0-9]{1,5})$ ]]; then
                low="${BASH_REMATCH[1]}"; high="$low"
            elif [[ "$item" =~ ^([0-9]{1,5})[-:]([0-9]{1,5})$ ]]; then
                low="${BASH_REMATCH[1]}"; high="${BASH_REMATCH[2]}"
            else
                continue
            fi
            (( 10#$low < 10#$start )) && low="$start"
            (( 10#$high > 10#$end )) && high="$end"
            for ((p=low; p<=high; p++)); do coverage[$((p-start))]=1; done
        done
    done
    if (( overlap )); then
        for idx in "${!coverage[@]}"; do (( coverage[$idx] == 1 )) || return 2; done
        return 0
    fi
    return 1
}

_firewall_service_range_state() {
    local backend="$1" start="$2" end="$3" proto="$4" entries_text item spec
    local -a entries=()
    entries_text=$(firewall_open_port_entries "$backend" 2>/dev/null) || return 3
    [[ -n "$entries_text" ]] || return 1
    # Profiles are external policy, not owned rules. Any overlap blocks a new broad rule.
    while IFS= read -r item; do
        [[ -n "$item" ]] || continue
        spec="${item%%|*}"
        if _firewall_port_spec_overlaps_range "$spec" "$start" "$end" "$proto"; then
            return 2
        fi
    done <<< "$entries_text"
    return 1
}

# Open a whole port-hopping range with one native firewall rule and record a
# single canonical START-END ownership entry. Existing full-range or full-cover
# rules are preserved without claiming ownership; partial/conflicting overlap
# is refused rather than creating hundreds of rules or broadening policy.
firewall_allow_range() {
    local range="$1" proto="$2" backend start end rc batch_mode="${EASY_VPN_FIREWALL_BATCH:-0}"
    validate_firewall_port_range "$range" || return 1
    case "$proto" in tcp|udp) ;; *) return 1 ;; esac
    start="${range%-*}"; end="${range#*-}"
    backend=$(firewall_backend)
    [[ "$backend" != none ]] || {
        echo -e "${YELLOW}[提示]${PLAIN} 当前未检测到已启用的 UFW/firewalld，未自动开启防火墙。"
        return 0
    }

    if _firewall_service_range_state "$backend" "$start" "$end" "$proto"; then rc=0; else rc=$?; fi
    case "$rc" in
        1) ;;
        2)
            echo -e "${YELLOW}[安全保留]${PLAIN} ${backend} 的 service/profile 规则与 ${range}/${proto} 重叠；拒绝添加宽范围规则。" >&2
            return 1 ;;
        *)
            echo -e "${YELLOW}[安全保留]${PLAIN} 无法核实 ${backend} 的 service/profile 规则；拒绝添加 ${range}/${proto}。" >&2
            return 1 ;;
    esac

    case "$backend" in
        ufw)
            if _firewall_ufw_range_state "$start" "$end" "$proto"; then rc=0; else rc=$?; fi
            case "$rc" in
                0) return 0 ;; # Existing global rules already cover the full range.
                1) ;;
                *)
                    echo -e "${YELLOW}[安全保留]${PLAIN} UFW 在 ${range}/${proto} 范围内有部分或冲突规则；拒绝再添加整段放行。" >&2
                    return 1 ;;
            esac
            ufw allow "${start}:${end}/${proto}" >/dev/null || return 1
            if ! firewall_record_new_rule ufw "$range" "$proto"; then
                ufw --force delete allow "${start}:${end}/${proto}" >/dev/null 2>&1 || true
                return 1
            fi
            ;;
        firewalld)
            if _firewall_firewalld_range_state "$start" "$end" "$proto"; then rc=0; else rc=$?; fi
            case "$rc" in
                0) return 0 ;; # Existing global rules already cover the full range.
                1) ;;
                *)
                    echo -e "${YELLOW}[安全保留]${PLAIN} firewalld 在 ${range}/${proto} 范围内有部分或冲突规则；拒绝再添加整段放行。" >&2
                    return 1 ;;
            esac
            firewall-cmd --permanent --add-port="${start}-${end}/${proto}" >/dev/null || return 1
            if ! firewall_record_new_rule firewalld "$range" "$proto"; then
                firewall-cmd --permanent --remove-port="${start}-${end}/${proto}" >/dev/null 2>&1 || true
                return 1
            fi
            if [[ "$batch_mode" != 1 ]]; then firewall-cmd --reload >/dev/null || return 1; fi
            ;;
    esac
}

# Remove only the exact native range that Easy VPN recorded as owned.
firewall_remove_owned_range() {
    local backend="$1" range="$2" proto="$3" start end status_text line token action exact=0
    validate_firewall_port_range "$range" || return 1
    case "$proto" in tcp|udp) ;; *) return 1 ;; esac
    start="${range%-*}"; end="${range#*-}"
    case "$backend" in
        ufw)
            status_text=$(ufw status numbered 2>/dev/null) || return 1
            while IFS= read -r line; do
                action=""
                for token in $line; do case "$token" in ALLOW|DENY|REJECT|LIMIT) action="$token"; break ;; esac; done
                for token in $line; do
                    [[ "$token" == "${start}:${end}/${proto}" ]] || continue
                    [[ "$action" == ALLOW ]] || {
                        echo -e "${YELLOW}[安全保留]${PLAIN} UFW 中存在同范围的非 ALLOW 规则；拒绝删除 ${range}/${proto}。" >&2
                        return 1
                    }
                    exact=1
                done
            done <<< "$status_text"
            (( exact )) || return 0
            ufw --force delete allow "${start}:${end}/${proto}" >/dev/null 2>&1 || return 1
            ;;
        firewalld)
            if ! firewall-cmd --query-port="${start}-${end}/${proto}" --permanent >/dev/null 2>&1; then return 0; fi
            firewall-cmd --permanent --remove-port="${start}-${end}/${proto}" >/dev/null 2>&1 || return 1
            if [[ "${EASY_VPN_FIREWALL_BATCH:-0}" != 1 ]]; then firewall-cmd --reload >/dev/null 2>&1 || return 1; fi
            ;;
        *) return 1 ;;
    esac
}

# Query whether a specific port/protocol is already allowed by the active host firewall.
firewall_rule_exists() {
    local backend="$1" port="$2" proto="$3"
    validate_port_any "$port" || return 1
    case "$proto" in tcp|udp) ;; *) return 1 ;; esac
    case "$backend" in
        ufw)
            command_exists ufw || return 1
            if ufw status 2>/dev/null | grep -Eq "^[[:space:]]*${port}/${proto}([[:space:]]|$)"; then
                return 0
            fi
            firewall_port_has_service_rule ufw "$port" "$proto"
            ;;
        firewalld)
            command_exists firewall-cmd || return 1
            if firewall-cmd --query-port="${port}/${proto}" --permanent >/dev/null 2>&1; then
                return 0
            fi
            firewall_port_has_service_rule firewalld "$port" "$proto"
            ;;
        *)
            return 1
            ;;
    esac
}

# Expand a service/profile port declaration into "port/proto|服务:name" entries.
# Supported forms include 22/tcp, 80,443/tcp and a single port range.
_firewall_emit_service_specs() {
    local service="$1" spec ports proto item
    shift
    local -a items=()
    for spec in "$@"; do
        [[ "$spec" =~ ^([0-9]+(,[0-9]+)*|[0-9]+[-:][0-9]+)/((tcp|udp))$ ]] || continue
        ports="${spec%/*}"
        proto="${spec##*/}"
        if [[ "$ports" == *,* ]]; then
            IFS=',' read -r -a items <<< "$ports"
            for item in "${items[@]}"; do
                [[ "$item" =~ ^[0-9]+$ ]] || continue
                printf '%s/%s|服务:%s\n' "$item" "$proto" "$service"
            done
        else
            printf '%s/%s|服务:%s\n' "$ports" "$proto" "$service"
        fi
    done
}

# Return active service/profile-backed port declarations for UFW or firewalld.
# Output format is "port-or-range/proto|服务:service-name".
firewall_open_port_entries() {
    local backend="$1" target status_text profile_info zone services service line specs
    local -a items=()
    case "$backend" in
        ufw)
            command_exists ufw || return 1
            status_text=$(ufw status 2>/dev/null) || return 1
            [[ "$status_text" == *"Status: active"* ]] || return 0
            while IFS= read -r target; do
                [[ -n "$target" ]] || continue
                # Explicit port rules are not app profiles. Non-port ALLOW targets
                # such as OpenSSH / Apache Full are resolved via `ufw app info`.
                [[ "$target" =~ ^[0-9]+([,:][0-9]+)*([:-][0-9]+)?(/[[:alpha:]]+)?$ ]] && continue
                [[ "$target" =~ ^[0-9A-Fa-f:.]+/[0-9]+$ ]] && continue
                profile_info=$(ufw app info "$target" 2>/dev/null) || return 1
                specs=$(awk '
                    /^[[:space:]]*Ports?:/ {
                        line=$0; sub(/^[^:]*:[[:space:]]*/, "", line)
                        if (line != "") print line
                        in_ports=1; next
                    }
                    in_ports && /^[[:space:]]*[0-9][0-9,:-]*\/(tcp|udp)([[:space:]]|$)/ {
                        sub(/^[[:space:]]+/, ""); print; next
                    }
                    in_ports && /^[^[:space:]]/ { in_ports=0 }
                ' <<< "$profile_info")
                [[ -n "$specs" ]] || return 1
                while IFS= read -r line; do
                    # Profile files may put multiple port tokens on a line.
                    read -r -a items <<< "$line"
                    _firewall_emit_service_specs "$target" "${items[@]}"
                done <<< "$specs"
            done < <(awk '
                /ALLOW/ {
                    line=$0
                    if (match(line, /[[:space:]][[:space:]]+ALLOW/)) {
                        target=substr(line, 1, RSTART-1)
                        gsub(/^[[:space:]]+|[[:space:]]+$/, "", target)
                        # UFW duplicates IPv6 rows with a trailing (v6) marker.
                        sub(/[[:space:]]+\(v6\)$/, "", target)
                        if (target != "") print target
                    }
                }
            ' <<< "$status_text")
            ;;
        firewalld)
            command_exists firewall-cmd || return 1
            zone=$(firewall-cmd --get-default-zone 2>/dev/null) || return 1
            [[ -n "$zone" ]] || return 1
            services=$(firewall-cmd --permanent --zone="$zone" --list-services 2>/dev/null) || return 1
            for service in $services; do
                profile_info=$(firewall-cmd --info-service="$service" 2>/dev/null) || return 1
                specs=$(awk '
                    tolower($0) ~ /^[[:space:]]*ports:/ {
                        line=$0; sub(/^[^:]*:[[:space:]]*/, "", line)
                        if (line != "") print line
                    }
                ' <<< "$profile_info")
                [[ -n "$specs" ]] || continue
                while IFS= read -r line; do
                    read -r -a items <<< "$line"
                    _firewall_emit_service_specs "$service" "${items[@]}"
                done <<< "$specs"
            done
            ;;
        *)
            return 1
            ;;
    esac
}

_firewall_service_spec_covers_port() {
    local spec="$1" port="$2" proto="$3" port_spec low high
    [[ "$spec" == */"$proto" ]] || return 1
    port_spec="${spec%/*}"
    if [[ "$port_spec" =~ ^([0-9]+)$ ]]; then
        (( 10#$port == 10#${BASH_REMATCH[1]} ))
        return
    fi
    if [[ "$port_spec" =~ ^([0-9]+)[-:]([0-9]+)$ ]]; then
        low="${BASH_REMATCH[1]}"; high="${BASH_REMATCH[2]}"
        (( 10#$port >= 10#$low && 10#$port <= 10#$high ))
        return
    fi
    return 1
}

firewall_port_has_service_rule() {
    local backend="$1" port="$2" proto="$3" item rule source entries_text
    local -a entries=()
    validate_port_any "$port" || return 1
    case "$proto" in tcp|udp) ;; *) return 1 ;; esac
    # If the active backend cannot be inspected, err on the side of preserving
    # the rule instead of silently weakening the deletion safeguard.
    if ! entries_text=$(firewall_open_port_entries "$backend" 2>/dev/null); then
        echo -e "${YELLOW}[安全保留]${PLAIN} 无法核实 ${backend} 的 service/profile 规则，拒绝自动删除 ${port}/${proto}。" >&2
        return 2
    fi
    if [[ -n "$entries_text" ]]; then
        mapfile -t entries <<< "$entries_text"
    fi
    for item in "${entries[@]}"; do
        rule="${item%%|*}"
        source="${item#*|}"
        if [[ "$source" == *"服务:"* ]] && _firewall_service_spec_covers_port "$rule" "$port" "$proto"; then
            return 0
        fi
    done
    return 1
}

firewall_remove_owned_rule() {
    local backend="$1" port="$2" proto="$3" rule_count service_check_status rule_output matching_rules v4_count v6_count batch_mode="${EASY_VPN_FIREWALL_BATCH:-0}"
    validate_port_any "$port" || return 1
    case "$proto" in tcp|udp) ;; *) return 1 ;; esac
    case "$backend" in
        ufw)
            if firewall_port_has_service_rule "$backend" "$port" "$proto"; then
                echo -e "${YELLOW}[安全保留]${PLAIN} ${port}/${proto} 由 UFW service/profile 管理，拒绝按端口强删。"
                return 1
            else
                service_check_status=$?
                if (( service_check_status != 1 )); then
                    echo -e "${YELLOW}[安全保留]${PLAIN} 无法可靠判断 UFW service/profile 规则，拒绝删除 ${port}/${proto}。"
                    return 1
                fi
            fi
            rule_output=$(ufw status numbered 2>/dev/null) || {
                echo -e "${YELLOW}[安全保留]${PLAIN} 无法读取 UFW 编号规则，拒绝删除 ${port}/${proto}。"
                return 1
            }
            matching_rules=$(printf '%s\n' "$rule_output" | \
                sed -E 's/^[[:space:]]*\[[[:space:]]*[0-9]+[[:space:]]*\][[:space:]]*//' | \
                grep -E "^${port}/${proto}([[:space:]]|$)" || true)
            rule_count=$(printf '%s\n' "$matching_rules" | grep -c . || true)
            if (( rule_count == 0 )); then
                return 0
            fi
            if (( rule_count == 2 )); then
                # UFW normally creates one IPv4 row and one explicit (v6) row.
                v6_count=$(printf '%s\n' "$matching_rules" | grep -Ec "^${port}/${proto}[[:space:]]+\(v6\)([[:space:]]|$)" || true)
                v4_count=$(printf '%s\n' "$matching_rules" | grep -Ev "^${port}/${proto}[[:space:]]+\(v6\)([[:space:]]|$)" | grep -c . || true)
                if (( v4_count != 1 || v6_count != 1 )); then
                    echo -e "${YELLOW}[安全保留]${PLAIN} 检测到 ${port}/${proto} 存在重复或冲突规则，并非标准 IPv4/IPv6 双栈组合，拒绝自动删除。"
                    return 1
                fi
            elif (( rule_count != 1 )); then
                echo -e "${YELLOW}[安全保留]${PLAIN} 检测到 ${port}/${proto} 存在多条防火墙规则，拒绝按端口强删，请手动处理。"
                return 1
            fi
            # Deleting by rule specification removes its paired IPv4/IPv6 rules; force avoids a hidden prompt.
            ufw --force delete allow "${port}/${proto}" >/dev/null 2>&1
            ;;
        firewalld)
            if firewall_port_has_service_rule "$backend" "$port" "$proto"; then
                echo -e "${YELLOW}[安全保留]${PLAIN} ${port}/${proto} 由 firewalld service/profile 管理，拒绝按端口强删。"
                return 1
            else
                service_check_status=$?
                if (( service_check_status != 1 )); then
                    echo -e "${YELLOW}[安全保留]${PLAIN} 无法可靠判断 firewalld service/profile 规则，拒绝删除 ${port}/${proto}。"
                    return 1
                fi
            fi
            if ! firewall-cmd --query-port="${port}/${proto}" --permanent >/dev/null 2>&1; then
                return 0
            fi
            firewall-cmd --permanent --remove-port="${port}/${proto}" >/dev/null 2>&1 || return 1
            if [[ "$batch_mode" != "1" ]]; then
                firewall-cmd --reload >/dev/null 2>&1 || return 1
            fi
            ;;
        *)
            return 1
            ;;
    esac
}

firewall_remove_owned_rules() {
    local backend port proto file failed dir="${EASY_VPN_STATE}/firewall"

    # 传入端口/协议时，只删除该条由工具记录的规则；不传参数则清理全部已记录规则。
    if [[ $# -eq 2 ]]; then
        port="$1"
        proto="$2"
        validate_port_any "$port" || return 1
        case "$proto" in tcp|udp) ;; *) return 1 ;; esac
        file="${dir}/${proto}_${port}.rule"
        if [[ ! -e "$file" && ! -L "$file" ]]; then
            echo -e "${BLUE}[保留]${PLAIN} ${port}/${proto} 没有 Easy VPN 的规则所有权记录；不修改现有防火墙规则。"
            return 0
        fi
        [[ -f "$file" && ! -L "$file" ]] || return 1
        backend=$(sed -n '1p' "$file")
        if firewall_remove_owned_rule "$backend" "$port" "$proto"; then
            rm -f "$file"
            return 0
        fi
        echo -e "${YELLOW}[警告]${PLAIN} 防火墙规则 ${port}/${proto} 未能删除，保留记录以便后续重试。"
        return 1
    fi

    [[ -d "$dir" ]] || return 1
    failed=0
    for file in "$dir"/*.rule; do
        [[ -f "$file" ]] || continue
        backend=$(sed -n '1p' "$file")
        port=$(sed -n '2p' "$file")
        proto=$(sed -n '3p' "$file")
        if firewall_remove_owned_rule "$backend" "$port" "$proto"; then
            rm -f "$file"
        else
            failed=1
            echo -e "${YELLOW}[警告]${PLAIN} 防火墙规则 ${port}/${proto} 未能删除，保留记录以便后续重试。"
        fi
    done
    return "$failed"
}

firewall_close_port_rule() {
    local port="$1" proto="$2" backend
    validate_port_any "$port" || return 1
    case "$proto" in tcp|udp) ;; *) return 1 ;; esac
    backend=$(firewall_backend)
    case "$backend" in
        ufw)
            ufw status 2>/dev/null | grep -Eq "^[[:space:]]*${port}/${proto}([[:space:]]|$)" || return 2
            ufw delete allow "${port}/${proto}" >/dev/null 2>&1
            ;;
        firewalld)
            firewall-cmd --query-port="${port}/${proto}" --permanent >/dev/null 2>&1 || return 2
            firewall-cmd --permanent --remove-port="${port}/${proto}" >/dev/null 2>&1 || return 1
            firewall-cmd --reload >/dev/null 2>&1 || return 1
            ;;
        *)
            return 1
            ;;
    esac
}

validate_port_any() {
    local port="$1"
    [[ "$port" =~ ^[0-9]+$ ]] && ((10#$port >= 1 && 10#$port <= 65535))
}

