#!/usr/bin/env bash
set -Eeuo pipefail
ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
. "$ROOT_DIR/linux/.join-to-domain/lib/configure/api.sh"
. "$ROOT_DIR/linux/.join-to-domain/lib/cleanup.sh"
log() { :; }
api_rootdse_response() { printf '%s' "$PAYLOAD"; }
cleanup_api_search() { printf '%s' "$PAYLOAD"; }
for attribute in defaultNamingContext rootDomainNamingContext namingContexts; do
  PAYLOAD="{\"$attribute\":[\"DC=MD,DC=LOC\"],\"dnsHostName\":[\"rediz-loc.md.loc\"]}"
  [[ "$(api_rootdse_domain session)" == md.loc ]]
  [[ "$(cleanup_api_rootdse_domain endpoint session)" == md.loc ]]
done
PAYLOAD='{"defaultNamingContext":["dc=other,dc=loc"],"dnsHostName":["rediz-loc.md.loc"]}'
[[ "$(api_rootdse_domain session)" == other.loc ]]
[[ "$(cleanup_api_rootdse_domain endpoint session)" == other.loc ]]
for attribute in dnsDomainName dnsForestName; do
  PAYLOAD="{\"$attribute\":[\"md.loc\"],\"dnsHostName\":[\"rediz-loc.md.loc\"]}"
  [[ "$(api_rootdse_domain session)" == md.loc ]]
  [[ "$(cleanup_api_rootdse_domain endpoint session)" == md.loc ]]
done
PAYLOAD='{"dnsHostName":["rediz-loc.md.loc"]}'
[[ -z "$(api_rootdse_domain session)" ]]
[[ -z "$(cleanup_api_rootdse_domain endpoint session)" ]]
. "$ROOT_DIR/linux/.join-to-domain/lib/configure/leave.sh"
env_has_key() { return 1; }
read_tty() { printf -v "$1" '%s' admin; }
read_secret_tty() { printf -v "$1" '%s' test-password; }
ui_text() { printf '%s' "$1"; }
activity_start() { :; }
activity_stop() { :; }
api_auth_cookie() { printf '%s' session; }
die() { printf '%s\n' "$*" >&2; exit 1; }
SAVED_DOMAIN=md.loc
for controller in rediz-loc.md.loc dc-moscow.md.loc dc-vladivostok.md.loc; do
  PAYLOAD="{\"defaultNamingContext\":[\"dc=md,dc=loc\"],\"rootDomainNamingContext\":[\"dc=forest,dc=loc\"],\"dnsHostName\":[\"$controller\"]}"
  validate_leave_credentials service-ready
  [[ "$(cleanup_api_rootdse_domain endpoint session)" == md.loc ]]
done
PAYLOAD='{"defaultNamingContext":["dc=other,dc=loc"],"dnsHostName":["dc.other.loc"]}'
if (validate_leave_credentials service-ready) 2>/dev/null; then
  printf 'Leave accepted a different domain\n' >&2
  exit 1
fi
printf 'RootDSE domain regression tests passed\n'
