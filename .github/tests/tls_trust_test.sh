#!/usr/bin/env bash
set -Eeuo pipefail
ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf -- "$TMP_ROOT"' EXIT
mkdir "$TMP_ROOT/bin"
cat > "$TMP_ROOT/bin/curl" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "${CURL_CA_BUNDLE:-system}:$*" >> "$TEST_CALLS"
if [[ -n "${CURL_CA_BUNDLE:-}" ]]; then rc="$PIN_RC"; else rc="$SYSTEM_RC"; fi
[[ "$rc" == 0 ]] || printf 'mock TLS failure %s\n' "$rc" >&2
exit "$rc"
MOCK
chmod +x "$TMP_ROOT/bin/curl"
export PATH="$TMP_ROOT/bin:$PATH"
export TEST_CALLS="$TMP_ROOT/calls" PIN_RC=0 SYSTEM_RC=0
export CURL_CA_BUNDLE="$TMP_ROOT/server.pem"
printf 'test certificate\n' > "$CURL_CA_BUNDLE"
API_HOST=md.ru
API_RESOLVED_IP=192.168.69.110
API_CURL_RESOLVE=(--resolve md.ru:443:192.168.69.110)
API_CONNECT_TIMEOUT=5
API_MAX_TIME=10
ALT=1
is_altlinux() { [[ "$ALT" == 1 ]]; }
log() { printf '%s\n' "$*" >> "$TMP_ROOT/log"; }
warn() { printf '%s\n' "$*" >> "$TMP_ROOT/warnings"; }
die() { printf '%s\n' "$*" >&2; exit 1; }
ui_text() { printf '%s' "$1"; }
# shellcheck source=/dev/null
. "$ROOT_DIR/linux/.join-to-domain/lib/configure/trust.sh"
verify_md_server_tls
[[ "$(wc -l < "$TEST_CALLS")" == 2 ]]
grep -q -- '--cacert' "$TEST_CALLS"
SYSTEM_RC=60
verify_md_server_tls
grep -q 'API TLS verification uses the accepted' "$TMP_ROOT/warnings"
grep -q 'trust=ALT_system_store; curl_exit=60; detail=mock TLS failure 60' "$TMP_ROOT/log"
for PIN_RC in 60 6 7 28 35; do
  : > "$TEST_CALLS"
  if (verify_md_server_tls) 2>/dev/null; then exit 1; fi
  [[ "$(wc -l < "$TEST_CALLS")" == 1 ]]
done
PIN_RC=0
SYSTEM_RC=28
if (verify_md_server_tls) 2>/dev/null; then exit 1; fi
ALT=0
: > "$TEST_CALLS"
verify_md_server_tls
[[ "$(wc -l < "$TEST_CALLS")" == 1 ]]
CURL_CA_BUNDLE="$TMP_ROOT/missing.pem"
: > "$TEST_CALLS"
if (verify_md_server_tls) 2>/dev/null; then exit 1; fi
[[ ! -s "$TEST_CALLS" ]]
printf 'TLS trust regression tests passed\n'
