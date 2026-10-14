#!/usr/bin/env bash
# Easy VPN 维护者发布工具（仅维护者使用，不会被安装到用户的 VPS 上）。
#
# 作用：为发布包生成并签署 SHA256SUMS，让用户的安装器在更新时能验证
#       “这些文件确实是维护者发布的”，即使下载经过第三方加速代理或镜像。
#
# 用法：
#   bash tools/release.sh init-key   # 第一次使用：生成签名密钥对（私钥只保存在本机）
#   bash tools/release.sh release    # 每次发布：写入公钥 → 生成 SHA256SUMS → 签名 → 自检
#   bash tools/release.sh verify     # 只验证当前仓库里的 SHA256SUMS(.sig)
#
# 私钥默认保存在 ~/.easy-vpn-release/release-private.pem（权限 600）。
# 绝对不要把私钥上传到 GitHub、发给任何人或放进 VPS；请另做离线备份。
# 私钥丢失后只能重新生成密钥，并让用户重新安装一次。
set -Eeuo pipefail
umask 077

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
KEY_DIR="${EASY_VPN_RELEASE_KEY_DIR:-${HOME}/.easy-vpn-release}"
PRIV="${KEY_DIR}/release-private.pem"
PUB="${KEY_DIR}/release-public.pem"
FILES=(install.sh lib/common.sh modules/protocol.sh protocol_catalog.json VERSION)

die() { echo "错误：$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "缺少命令：$1"; }
need openssl; need sha256sum; need awk; need sed
TMPD="$(mktemp -d)"
trap 'rm -rf -- "$TMPD"' EXIT

init_key() {
    [[ ! -e "$PRIV" && ! -e "$PUB" ]] || die "密钥已存在：${KEY_DIR}（为避免误覆盖，不会重新生成）"
    mkdir -p -- "$KEY_DIR"
    chmod 700 -- "$KEY_DIR"
    openssl ecparam -name prime256v1 -genkey -noout -out "$PRIV" 2>/dev/null
    chmod 600 -- "$PRIV"
    openssl ec -in "$PRIV" -pubout -out "$PUB" 2>/dev/null
    chmod 644 -- "$PUB"
    echo "已生成签名密钥对："
    echo "  私钥：$PRIV    ← 仅保存在本机并做离线备份，绝不要上传"
    echo "  公钥：$PUB"
    echo "下一步：bash tools/release.sh release"
}

check_versions() {
    local v_file v_install v_catalog
    v_file="$(tr -d '[:space:]' < "${ROOT}/VERSION")"
    v_install="$(grep -m1 '^CURRENT_VERSION=' "${ROOT}/install.sh" | cut -d'"' -f2)"
    v_catalog="$(sed -n 's/^[[:space:]]*"tool_version":[[:space:]]*"\([^"]*\)".*/\1/p' "${ROOT}/protocol_catalog.json" | head -n1)"
    [[ "$v_file" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "VERSION 格式无效：${v_file}"
    [[ "$v_file" == "$v_install" && "$v_file" == "$v_catalog" ]] \
        || die "版本号不一致：VERSION=${v_file} install.sh=${v_install} catalog=${v_catalog}"
}

inject_pubkey() {
    local tmp
    [[ -f "$PUB" ]] || die "找不到公钥，请先运行：bash tools/release.sh init-key"
    grep -q '^# >>> EASY_VPN_RELEASE_PUBKEY >>>$' "${ROOT}/install.sh" || die "install.sh 缺少公钥标记块"
    grep -q '^# <<< EASY_VPN_RELEASE_PUBKEY <<<$' "${ROOT}/install.sh" || die "install.sh 缺少公钥标记块结尾"
    tmp="$(mktemp "${ROOT}/.install.sh.XXXXXX")"
    PUBKEY_TEXT="$(cat -- "$PUB")" awk -v q="'" '
        /^# >>> EASY_VPN_RELEASE_PUBKEY >>>$/ { print; print "EASY_VPN_RELEASE_PUBKEY=" q ENVIRON["PUBKEY_TEXT"] q; skip = 1; next }
        /^# <<< EASY_VPN_RELEASE_PUBKEY <<<$/ { skip = 0 }
        !skip { print }
    ' "${ROOT}/install.sh" > "$tmp"
    bash -n "$tmp" || { rm -f -- "$tmp"; die "写入公钥后 install.sh 语法检查失败"; }
    chmod --reference="${ROOT}/install.sh" "$tmp"
    mv -f -- "$tmp" "${ROOT}/install.sh"
}

embedded_pubkey() {
    # 取出 install.sh 里的公钥（与用户安装器实际使用的内容完全一致）
    awk '
        /^EASY_VPN_RELEASE_PUBKEY=/ { on = 1; sub(/^EASY_VPN_RELEASE_PUBKEY=\047/, "") }
        on { if ($0 ~ /\047$/) { sub(/\047$/, ""); print; exit } print }
    ' "${ROOT}/install.sh"
}

verify_all() {
    local pub file expected actual
    pub="$(embedded_pubkey)"
    [[ -n "$pub" ]] || die "install.sh 里没有公钥（尚未发布签名）"
    [[ -s "${ROOT}/SHA256SUMS" && -s "${ROOT}/SHA256SUMS.sig" ]] || die "缺少 SHA256SUMS 或 SHA256SUMS.sig"
    printf '%s\n' "$pub" > "${TMPD}/pub.pem"
    openssl base64 -d -A -in "${ROOT}/SHA256SUMS.sig" -out "${TMPD}/sig.bin" 2>/dev/null || die "SHA256SUMS.sig 不是有效的 base64"
    openssl dgst -sha256 -verify "${TMPD}/pub.pem" -signature "${TMPD}/sig.bin" "${ROOT}/SHA256SUMS" >/dev/null 2>&1 \
        || die "签名校验失败：SHA256SUMS 与 install.sh 内的公钥不匹配"
    for file in "${FILES[@]}"; do
        expected="$(awk -v f="$file" '$2 == f { print $1; exit }' "${ROOT}/SHA256SUMS")"
        actual="$(sha256sum -- "${ROOT}/${file}" | awk '{print $1}')"
        [[ -n "$expected" && "$expected" == "$actual" ]] || die "文件哈希与 SHA256SUMS 不一致：${file}（修改文件后需要重新运行 release）"
    done
    echo "校验通过：签名有效，且 ${#FILES[@]} 个文件哈希全部一致。"
}

release() {
    local file
    [[ -f "$PRIV" ]] || die "找不到私钥：${PRIV}。第一次使用请先运行：bash tools/release.sh init-key"
    for file in "${FILES[@]}"; do [[ -f "${ROOT}/${file}" ]] || die "缺少发布文件：${file}"; done
    for file in install.sh lib/common.sh modules/protocol.sh; do bash -n "${ROOT}/${file}" || die "Bash 语法错误：${file}"; done
    check_versions
    inject_pubkey
    (cd -- "$ROOT" && sha256sum -- "${FILES[@]}" > SHA256SUMS)
    openssl dgst -sha256 -sign "$PRIV" -out "${TMPD}/sig.bin" "${ROOT}/SHA256SUMS"
    openssl base64 -A -in "${TMPD}/sig.bin" -out "${ROOT}/SHA256SUMS.sig"
    printf '\n' >> "${ROOT}/SHA256SUMS.sig"
    verify_all
    echo
    echo "发布版本：$(tr -d '[:space:]' < "${ROOT}/VERSION")"
    echo "install.sh 的 SHA-256（可写进 README，供用户首次安装前核对）："
    sha256sum -- "${ROOT}/install.sh" | awk '{print "  " $1}'
    echo
    echo "请把以下文件全部上传/提交到 GitHub 仓库 main 分支（缺一不可）："
    printf '  %s\n' "${FILES[@]}" SHA256SUMS SHA256SUMS.sig
    echo "之后只要再修改上面任何一个文件，都必须重新运行：bash tools/release.sh release"
}

case "${1:-release}" in
    init-key) init_key ;;
    release)  release ;;
    verify)   verify_all ;;
    -h|--help|help) sed -n '2,17p' "${BASH_SOURCE[0]}" ;;
    *) die "未知命令：${1}（可用：init-key | release | verify）" ;;
esac
