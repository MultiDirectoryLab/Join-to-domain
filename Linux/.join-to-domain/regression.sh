#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"

run_keytab_principal_render_tests() (
  local tmp_root rendered template
  tmp_root="$(mktemp -d)"
  trap 'rm -rf -- "$tmp_root"' EXIT

  warn() { printf 'warning: %s\n' "$*" >&2; }
  die() { printf 'error: %s\n' "$*" >&2; exit 1; }
  log() { :; }

  # shellcheck source=/dev/null
  . "$ROOT_DIR/Linux/.join-to-domain/lib/configure/templates.sh"
  # shellcheck source=/dev/null
  . "$ROOT_DIR/Linux/.join-to-domain/lib/configure/local_config.sh"

  DOMAIN=md.loc
  REALM=MD.LOC
  KDC=md.loc
  KADMIN=md.loc
  URI=ldap://md.loc
  LDAP_SEARCH_BASE=dc=md,dc=loc
  LDAP_USER_BASE=dc=md,dc=loc
  LDAP_GROUP_BASE=dc=md,dc=loc
  LDAP_COMPUTER_OU=cn=computers
  HOSTNAME=astra-27030
  FQDN=astra-27030.md.loc
  SALT_MASTER=
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
    rendered="$tmp_root/$template"
    cp "$ROOT_DIR/Linux/.join-to-domain/files/sssd.conf.d/$template" "$rendered"
    apply_placeholders_to_file "$rendered"
    grep -Fxq 'ldap_sasl_authid = HOST/astra-27030.md.loc@MD.LOC' "$rendered"
    ! grep -Eq '__[A-Z0-9_]+__' "$rendered"
  done

  unset KEYTAB_HOST_PRINCIPAL
  rendered="$tmp_root/pre-keytab.conf"
  cp "$ROOT_DIR/Linux/.join-to-domain/files/sssd.conf.d/default-sssd.conf" "$rendered"
  apply_placeholders_to_file "$rendered"
  grep -Fxq 'ldap_sasl_authid = host/astra-27030.md.loc@MD.LOC' "$rendered"
  is_supported_template_placeholder __LDAP_SASL_AUTHID__

  printf 'keytab principal render tests: OK\n'
)

run_recovery_state_tests() (
  local tmp_root first_backup second_backup
  tmp_root="$(mktemp -d)"
  trap 'rm -rf -- "$tmp_root"' EXIT

  . "$ROOT_DIR/Linux/.join-to-domain/lib/configure/common.sh"
  . "$ROOT_DIR/Linux/.join-to-domain/lib/configure/state.sh"
  . "$ROOT_DIR/Linux/.join-to-domain/lib/configure/leave.sh"
  . "$ROOT_DIR/Linux/.join-to-domain/lib/domain_state.sh"
  . "$ROOT_DIR/Linux/.join-to-domain/lib/cleanup.sh"

  MD_ETC_DIR="$tmp_root/etc/MultiDirectory"
  MD_STATE_DIR="$MD_ETC_DIR/state"
  MD_BACKUPS_ROOT="$MD_ETC_DIR/backups"
  MD_JOIN_ENV="$MD_STATE_DIR/join.env"
  MD_PENDING_BACKUP="$MD_STATE_DIR/active-backup"
  MD_ORIGINAL_BACKUP="$MD_STATE_DIR/original-backup"
  MD_TRANSACTION_STATE="$MD_STATE_DIR/transaction.env"
  MD_ROLLBACK_MARKER="$MD_STATE_DIR/rollback-in-progress"
  LOG_FILE="$tmp_root/join.log"
  SYSTEM_FILE="$tmp_root/etc/example.conf"

  [[ "$(sanitize_input $'old\177\177\177new')" == new ]]
  [[ "$(sanitize_input $'abc\b\bZ')" == aZ ]]
  managed_join_paths() { printf '%s\n' "$SYSTEM_FILE"; }
  is_redos_or_rhel_like() { return 1; }

  mkdir -p "$(dirname "$SYSTEM_FILE")"
  printf 'original\n' > "$SYSTEM_FILE"
  create_join_backup
  validate_join_backup
  first_backup="$MD_BACKUP_DIR"
  [[ "$(<"$MD_PENDING_BACKUP")" == "$first_backup" ]]
  write_transaction_state JOIN_IN_PROGRESS join
  grep -q '^STATE=JOIN_IN_PROGRESS$' "$MD_TRANSACTION_STATE"
  grep -q '^OPERATION=join$' "$MD_TRANSACTION_STATE"
  publish_original_backup "$first_backup"
  [[ "$(<"$MD_ORIGINAL_BACKUP")" == "$first_backup" ]]

  rm -f "$MD_JOIN_ENV"
  MD_BACKUP_DIR=
  MD_MANIFEST=
  load_prejoin_backup
  [[ "$MD_BACKUP_DIR" == "$first_backup" ]]
  validate_join_backup
  [[ "$(original_backup_manifest)" == "$first_backup/manifest.env" ]]
  [[ "$(authoritative_domain_manifest)" == "$first_backup/manifest.env" ]]

  sleep 1
  create_backup_set join
  second_backup="$MD_BACKUP_DIR"
  [[ "$second_backup" != "$first_backup" ]]
  ! publish_original_backup "$second_backup"
  [[ "$(<"$MD_ORIGINAL_BACKUP")" == "$first_backup" ]]

  rm -f "$MD_PENDING_BACKUP" "$MD_ORIGINAL_BACKUP" "$MD_JOIN_ENV"
  DETECTED_DOMAIN_STATE=partial_join
  partial_without_recovery_metadata
  printf '%s\n' "$first_backup" > "$MD_PENDING_BACKUP"
  ! partial_without_recovery_metadata

  MD_BACKUP_DIR="$first_backup"
  MD_MANIFEST="$first_backup/manifest.env"
  write_state_pointer "$MD_PENDING_BACKUP" "$first_backup"
  write_transaction_state JOIN_IN_PROGRESS join
  touch "$MD_ROLLBACK_MARKER"
  warn() { :; }
  activity_start() { :; }
  activity_stop() { :; }
  user_ok() { :; }
  ui_text() { printf '%s' "$1"; }
  perform_local_rollback_cleanup() { return 1; }
  ! rollback_local_changes 42
  [[ -f "$MD_PENDING_BACKUP" && -f "$MD_TRANSACTION_STATE" && -f "$MD_ROLLBACK_MARKER" ]]
  grep -q '^STATE=ROLLBACK_IN_PROGRESS$' "$MD_TRANSACTION_STATE"

  perform_local_rollback_cleanup() { return 0; }
  rollback_local_changes 42
  [[ ! -e "$MD_STATE_DIR" ]]

  mkdir -p "$MD_STATE_DIR"
  printf 'STATE=ROLLBACK_FAILED\n' > "$MD_TRANSACTION_STATE"
  MD_MANIFEST="$MD_STATE_DIR/manifest"
  DRY_RUN=0
  DETECTED_DOMAIN_STATE=partial_join
  need_root_for_cleanup() { return 0; }
  cleanup_log() { :; }
  error() { :; }
  info() { :; }
  validate_pam_safety() { return 0; }
  validate_ssh_safety() { return 0; }
  stop_domain_services_for_cleanup() { :; }
  cleanup_remote_domain_objects() { :; }
  cleanup_kerberos_domain_state() { :; }
  cleanup_sssd_domain_state() { :; }
  cleanup_ssh_domain_state() { :; }
  cleanup_sssd_cache() { :; }
  cleanup_empty_domain_dirs() { :; }
  reload_services_after_cleanup() { :; }
  cleanup_domain_runtime_state() { return 1; }
  ! safe_leave_domain
  [[ -f "$MD_TRANSACTION_STATE" ]]
  cleanup_domain_runtime_state() { return 0; }
  safe_leave_domain
  [[ ! -e "$MD_TRANSACTION_STATE" ]]

  printf 'recovery state tests: OK\n'
)

run_capability_output_filter_test() {
  local output
  output="$({
    printf '%s\n' \
      'visible before' \
      "2026 Sep 18 13:55:02 astra-27030 Those capabilities aren't needed and can be removed:" \
      ' CAP_DAC_READ_SEARCH: effective = 1, permitted = 1, inheritable =  0 , bounding = 1' \
      ' CAP_SETGID: effective = 1, permitted = 1, inheritable =  0 , bounding = 1' \
      ' CAP_SETUID: effective = 1, permitted = 1, inheritable =  0 , bounding = 1' \
      'visible after'
  } | sed -u -E '/Those capabilities aren.t needed and can be removed:|CAP_(DAC_READ_SEARCH|SETGID|SETUID):.*effective[[:space:]]*=/d')"
  [[ "$output" == $'visible before\nvisible after' ]]

  printf 'capability output filter test: OK\n'
}

run_keytab_principal_render_tests
run_recovery_state_tests
run_capability_output_filter_test
printf 'regression tests: OK\n'
