#!/usr/bin/env bash
set -Eeuo pipefail
ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf -- "$TMP_ROOT"' EXIT

run_scenario() (
  set -Eeuo pipefail
  local operation="$1" scenario="$2" edition="$3" module
  local events="$TMP_ROOT/$operation-$scenario-$edition"
  : > "$events"
  for module in identity_dns state api validation rejoin flow; do
    # shellcheck source=/dev/null
    . "$ROOT_DIR/linux/.join-to-domain/lib/configure/$module.sh"
  done
  mark() { printf '%s\n' "$1" >> "$events"; }
  ui_text() { printf '%s' "$1"; }
  log() { :; }
  info() { :; }
  warn() { :; }
  ok() { :; }
  activity_start() { :; }
  activity_stop() { :; }
  user_info() { :; }
  user_ok() { :; }
  die() { mark "failure:$*"; exit 17; }
  on_join_error() { exit 18; }
  on_join_signal() { exit 19; }
  on_recovery_rejoin_error() { exit 18; }
  on_recovery_rejoin_signal() { exit 19; }
  preflight() { :; }
  need_root() { :; }
  need_cmd() { :; }
  setup_logging() { :; }
  load_os_release() { :; }
  recoverable_incomplete_join_detected() { return 1; }
  detect_domain_state() {
    if [[ "$operation" == join ]]; then DETECTED_DOMAIN_STATE=not_joined; else DETECTED_DOMAIN_STATE=managed_join; fi
  }
  env_has_key() { return 1; }
  load_join_state() { :; }
  load_join_env() { DOMAIN=md.ru; SAVED_DOMAIN=md.ru; SAVED_EDITION="$edition"; API_HOST=192.168.69.146; HOSTNAME=client; FQDN=client.md.ru; }
  classify_prejoin_backup() { PREJOIN_BACKUP_STATE=valid; }
  existing_domain_configuration_valid() { return 0; }
  create_join_backup() { mark backup; }
  create_recovery_backup() { mark backup; }
  validate_join_backup() { return 0; }
  write_transaction_state() { mark transaction; }
  md_init_state() { :; }
  prepare_service_info() {
    mark service-info
    [[ "$scenario" != api-failure ]] || return 1
    DOMAIN=md.ru
    [[ "$scenario" != saved-mismatch ]] || DOMAIN=other.ru
    EDITION="$edition"
    [[ "$scenario" != edition-mismatch ]] || EDITION=changed
    WITH_SALT=0
    [[ "$edition" != enterprise ]] || WITH_SALT=1
    API_HOST=192.168.69.146
    API_RESOLVED_IP=192.168.69.146
    MD_DNS_SERVER='10.0.0.3 10.0.0.4 10.0.0.2'
  }
  validate_files_structure() { mark "files:$EDITION"; }
  require_salt_minion_ready() { mark salt-ready; }
  prompt_configure_dns() {
    [[ "$MD_DNS_SERVER" == '10.0.0.3 10.0.0.4 10.0.0.2' ]]
    mark dns
  }
  read_tty() { printf -v "$1" '%s' test-admin; }
  read_secret_tty() { printf -v "$1" '%s' test-password; }
  api_auth_cookie() { mark auth; printf '%s' test-cookie; }
  validate_leave_credentials() { [[ "$1" == service-ready ]]; mark auth; access_token=test-cookie; }
  api_rootdse_response() {
    mark rootdse
    if [[ "$scenario" == rootdse-mismatch ]]; then
      printf '%s' '{"defaultNamingContext":"dc=other,dc=ru","dnsHostName":"dc.other.ru"}'
    else
      printf '%s' '{"defaultNamingContext":"dc=md,dc=ru","dnsHostName":"dc.md.ru"}'
    fi
  }
  discover_controller_fqdn() { CONTROLLER_FQDN="$1"; }
  controller_fqdn_resolves_to_address() { return 0; }
  configure_salt_master_from_api_ip() { mark salt-master; }
  prompt_change_hostname() { mark discovered; exit 0; }
  valid_hostname() { return 0; }
  resolve_computer_object() { mark remote-read; }
  recovery_rejoin_domain() { mark discovered; exit 0; }
  # These are writes and must never be reached before successful discovery.
  install_static_configs() { mark local-write; exit 20; }
  create_computer_object_if_needed() { mark remote-write; exit 20; }
  LOG_FILE="$TMP_ROOT/log"
  if [[ "$operation" == join ]]; then join_domain; else rejoin_domain_configure; fi
)

for operation in join rejoin; do
  for edition in enterprise community; do
    run_scenario "$operation" success "$edition"
    events="$TMP_ROOT/$operation-success-$edition"
    # All new discovery, DNS and administrator requests follow the backup.
    actual="$(grep -E '^(backup|transaction|service-info|dns|auth|rootdse|discovered)$' "$events" | paste -sd, -)"
    [[ "$actual" == backup,transaction,service-info,dns,auth,rootdse,discovered ]]
    grep -q "^files:$edition$" "$events"
    if [[ "$edition" == enterprise ]]; then grep -q '^salt-master$' "$events"; else ! grep -q '^salt-master$' "$events"; fi
    for scenario in api-failure rootdse-mismatch; do
      set +e
      run_scenario "$operation" "$scenario" "$edition"
      status=$?
      set -e
      [[ "$status" == 17 ]]
      events="$TMP_ROOT/$operation-$scenario-$edition"
      ! grep -Eq '^(remote-write|local-write|remote-read|discovered)$' "$events"
      if [[ "$scenario" == api-failure ]]; then ! grep -Eq '^(dns|auth|rootdse)$' "$events"; fi
      if [[ "$scenario" == rootdse-mismatch ]]; then grep -q 'RootDSE does not match service_info' "$events"; fi
    done
  done
done
set +e
run_scenario rejoin saved-mismatch enterprise
status=$?
set -e
[[ "$status" == 17 ]]
grep -q 'service_info does not match saved domain' "$TMP_ROOT/rejoin-saved-mismatch-enterprise"
! grep -Eq '^(dns|auth|rootdse|remote-read|discovered)$' "$TMP_ROOT/rejoin-saved-mismatch-enterprise"
set +e
run_scenario rejoin edition-mismatch enterprise
status=$?
set -e
[[ "$status" == 17 ]]
grep -q 'edition has changed' "$TMP_ROOT/rejoin-edition-mismatch-enterprise"
! grep -Eq '^(dns|auth|rootdse|remote-read|discovered)$' "$TMP_ROOT/rejoin-edition-mismatch-enterprise"
printf 'Service discovery flow regression tests passed\n'
