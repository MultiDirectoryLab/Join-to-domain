#!/usr/bin/env bash
set -Eeuo pipefail
ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf -- "$TMP_ROOT"' EXIT
# shellcheck source=/dev/null
. "$ROOT_DIR/linux/.join-to-domain/lib/configure/identity_dns.sh"
# shellcheck source=/dev/null
. "$ROOT_DIR/linux/.join-to-domain/lib/configure/state.sh"
# shellcheck source=/dev/null
. "$ROOT_DIR/linux/.join-to-domain/lib/configure/service_info.sh"
log() { :; }
warn() { printf '%s\n' "$*" >> "$TMP_ROOT/warnings"; }
sanitize_input() { printf '%s' "$1"; }
ui_text() { printf '%s' "$1"; }
API_HOST=192.168.69.146
API_CONNECT_TIMEOUT=2
API_MAX_TIME=5
API_CURL_RESOLVE=(--resolve 192.168.69.146:443:192.168.69.146)
HTTP_CODE=200
CURL_RC=0
PAYLOAD='{"domain_ldap_name":"md.ru","md_edition":"Enterprise","md_dns_servers":["10.0.0.5","10.0.0.4","10.0.0.2","10.0.0.1","10.0.0.3","10.0.0.2"]}'
curl() {
  local body=""
  printf '%s\n' "$*" > "$TMP_ROOT/curl-call"
  while (( $# )); do
    case "$1" in -o) body="$2"; shift ;; esac
    shift
  done
  printf '%s' "$PAYLOAD" > "$body"
  printf '%s' "$HTTP_CODE"
  return "$CURL_RC"
}
dig() {
  local ip="${1#@}" latency
  printf '%s\n' "$ip" >> "$TMP_ROOT/dns-calls"
  case "$ip" in
    10.0.0.1) return 9 ;;
    10.0.0.2) latency=30 ;;
    10.0.0.3) latency=5 ;;
    10.0.0.4) latency=15 ;;
    10.0.0.5) latency=80 ;;
    *) return 9 ;;
  esac
  printf ';; ->>HEADER<<- opcode: QUERY, status: NOERROR, id: 1\nmd.ru. 300 IN SOA dc.md.ru. root.md.ru. 1 2 3 4 5\n;; Query time: %s msec\n' "$latency"
}
load_service_info
[[ "$DOMAIN" == md.ru && "$EDITION" == enterprise && "$WITH_SALT" == 1 ]]
[[ "$MD_DNS_SERVER" == '10.0.0.3 10.0.0.4 10.0.0.2' ]]
[[ "$(wc -l < "$TMP_ROOT/dns-calls")" == 5 ]]
[[ "$JOIN_TO_DOMAIN_ENV_KEYS" == *' MD_DNS_SERVER '* ]]
grep -q '/api/system/service_info' "$TMP_ROOT/curl-call"
! grep -Eq -- '(^| )(-k|--insecure)( |$)' "$TMP_ROOT/curl-call"
PAYLOAD="${PAYLOAD/Enterprise/Community}"
load_service_info
[[ "$EDITION" == community && "$WITH_SALT" == 0 ]]
for PAYLOAD in \
  'invalid json' \
  '{}' \
  '{"domain_ldap_name":"md.ru","md_edition":"Unknown","md_dns_servers":["10.0.0.2"]}' \
  '{"domain_ldap_name":"md.ru","md_edition":"Enterprise","md_dns_servers":[]}' \
  '{"domain_ldap_name":"md.ru","md_edition":"Enterprise","md_dns_servers":[null]}' \
  '{"domain_ldap_name":"md.ru","md_edition":"Enterprise","md_dns_servers":["999.0.0.1"]}' \
  '{"domain_ldap_name":"md.ru","md_edition":"Enterprise","md_dns_servers":["10.0.0.1"]}' \
  '{"domain_ldap_name":"$(touch /tmp/never)","md_edition":"Enterprise","md_dns_servers":["10.0.0.2"]}' \
  '{"domain_ldap_name":"md.ru","md_edition":"Enterprise","md_dns_servers":["10.0.0.2"]} {}'; do
  DOMAIN=preserved.example
  EDITION=preserved-edition
  WITH_SALT=preserved-salt
  MD_DNS_SERVER=preserved-dns
  JOIN_TO_DOMAIN_ENV_KEYS=' PRESERVED_KEY '
  if load_service_info; then printf 'Accepted invalid service_info: %s\n' "$PAYLOAD" >&2; exit 1; fi
  [[ "$DOMAIN" == preserved.example && "$EDITION" == preserved-edition ]]
  [[ "$WITH_SALT" == preserved-salt && "$MD_DNS_SERVER" == preserved-dns ]]
  [[ "$JOIN_TO_DOMAIN_ENV_KEYS" == ' PRESERVED_KEY ' ]]
done
PAYLOAD='{"domain_ldap_name":"md.ru","md_edition":"Enterprise","md_dns_servers":["10.0.0.2"]}'
HTTP_CODE=503
if load_service_info; then exit 1; fi
HTTP_CODE=200
CURL_RC=28
if load_service_info; then exit 1; fi
CURL_RC=0
# An unresolved name must allow bootstrap by IP, before DNS is configured.
pin_api_host() {
  printf '%s\n' "$1" >> "$TMP_ROOT/pin-calls"
  [[ "$1" == 192.168.69.146 ]]
}
install_md_server_certificate() { :; }
tty_echo() { :; }
read_tty() {
  if [[ "$1" == choice ]]; then printf -v "$1" '%s' 1; else printf -v "$1" '%s' 192.168.69.146; fi
}
API_HOST=does-not-resolve.example
prepare_service_info
[[ "$API_HOST" == 192.168.69.146 && "$DOMAIN" == md.ru ]]
[[ "$(paste -sd, "$TMP_ROOT/pin-calls")" == does-not-resolve.example,192.168.69.146 ]]
# Saved host is also only a bootstrap hint: an obsolete DNS record can be
# recovered by entering its IP without changing the LDAP domain identity.
: > "$TMP_ROOT/pin-calls"
unset API_HOST
SAVED_API_HOST=old-saved.example
prepare_service_info
[[ "$API_HOST" == 192.168.69.146 && "$DOMAIN" == md.ru ]]
[[ "$(paste -sd, "$TMP_ROOT/pin-calls")" == old-saved.example,192.168.69.146 ]]
# An explicit IP takes priority over a saved name and asks no DNS fallback.
: > "$TMP_ROOT/pin-calls"
API_HOST=192.168.69.146
read_tty() { printf 'Unexpected prompt for an explicit IP\n' >&2; return 1; }
prepare_service_info
[[ "$(cat "$TMP_ROOT/pin-calls")" == 192.168.69.146 ]]
# Recovery by manually configuring DNS keeps the requested host and does
# not silently apply previously discovered server overrides.
API_HOST=unresolved.example
DNS_FIXED=0
JOIN_TO_DOMAIN_ENV_KEYS=' EDITION MD_DNS_SERVER '
pin_api_host() { [[ "$DNS_FIXED" == 1 && "$1" == unresolved.example ]]; }
read_tty() { printf -v "$1" '%s' 2; }
prompt_configure_dns() {
  [[ "$JOIN_TO_DOMAIN_ENV_KEYS" != *MD_DNS_SERVER* ]]
  DNS_FIXED=1
}
select_service_api_host
[[ "$API_HOST" == unresolved.example && "$DNS_FIXED" == 1 ]]
[[ "$JOIN_TO_DOMAIN_ENV_KEYS" == ' EDITION MD_DNS_SERVER ' ]]
# Cancel does not reach certificate installation or another API request.
pin_api_host() { return 1; }
read_tty() { printf -v "$1" '%s' 3; }
install_md_server_certificate() { touch "$TMP_ROOT/unexpected-certificate-install"; }
if prepare_service_info; then exit 1; fi
[[ ! -e "$TMP_ROOT/unexpected-certificate-install" ]]
printf 'Service info regression tests passed\n'
