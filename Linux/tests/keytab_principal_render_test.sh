#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf -- "$TMP_ROOT"' EXIT

warn() { printf 'warning: %s\n' "$*" >&2; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }
log() { :; }

# shellcheck source=/dev/null
. "$ROOT_DIR/Linux/.join-to-domain/lib/configure/templates.sh"
# shellcheck source=/dev/null
. "$ROOT_DIR/Linux/.join-to-domain/lib/configure/local_config.sh"

# These globals are consumed by the sourced template functions.
# shellcheck disable=SC2034
DOMAIN=md.loc
# shellcheck disable=SC2034
REALM=MD.LOC
# shellcheck disable=SC2034
KDC=md.loc
# shellcheck disable=SC2034
KADMIN=md.loc
# shellcheck disable=SC2034
URI=ldap://md.loc
# shellcheck disable=SC2034
LDAP_SEARCH_BASE=dc=md,dc=loc
# shellcheck disable=SC2034
LDAP_USER_BASE=dc=md,dc=loc
# shellcheck disable=SC2034
LDAP_GROUP_BASE=dc=md,dc=loc
# shellcheck disable=SC2034
LDAP_COMPUTER_OU=cn=computers
HOSTNAME=astra-27030
# shellcheck disable=SC2034
FQDN=astra-27030.md.loc
# shellcheck disable=SC2034
SALT_MASTER=
# shellcheck disable=SC2034
MD_DNS_SERVER=

klist() {
  printf '%s\n' \
    'Keytab name: FILE:/etc/krb5.keytab' \
    'KVNO Principal' \
    '---- --------------------------------------------------------------------------' \
    '   2 HOST/astra-27030@MD.LOC' \
    '   2 HOST/astra-27030.md.loc@MD.LOC'
}

select_keytab_host_principal /etc/krb5.keytab
[[ "$KEYTAB_HOST_PRINCIPAL" == 'HOST/astra-27030.md.loc@MD.LOC' ]]

for template in default-sssd.conf astra-se-parsec-sssd.conf; do
  rendered="$TMP_ROOT/$template"
  cp "$ROOT_DIR/Linux/.join-to-domain/files/sssd.conf.d/$template" "$rendered"
  apply_placeholders_to_file "$rendered"
  grep -Fxq 'ldap_sasl_authid = HOST/astra-27030.md.loc@MD.LOC' "$rendered"
  if grep -Eq '__[A-Z0-9_]+__' "$rendered"; then
    printf 'unresolved placeholder in %s\n' "$template" >&2
    exit 1
  fi
done

# Before a keytab is available, initial rendering retains the conventional
# lowercase host principal. The later keytab validation replaces it exactly.
unset KEYTAB_HOST_PRINCIPAL
rendered="$TMP_ROOT/pre-keytab.conf"
cp "$ROOT_DIR/Linux/.join-to-domain/files/sssd.conf.d/default-sssd.conf" "$rendered"
apply_placeholders_to_file "$rendered"
grep -Fxq 'ldap_sasl_authid = host/astra-27030.md.loc@MD.LOC' "$rendered"

is_supported_template_placeholder __LDAP_SASL_AUTHID__

printf 'keytab principal render tests: OK\n'
