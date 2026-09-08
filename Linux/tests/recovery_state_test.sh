#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf -- "$TMP_ROOT"' EXIT

# shellcheck source=/dev/null
. "$ROOT_DIR/Linux/.join-to-domain/lib/configure/common.sh"
# shellcheck source=/dev/null
. "$ROOT_DIR/Linux/.join-to-domain/lib/configure/state.sh"
# shellcheck source=/dev/null
. "$ROOT_DIR/Linux/.join-to-domain/lib/configure/leave.sh"
# shellcheck source=/dev/null
. "$ROOT_DIR/Linux/.join-to-domain/lib/domain_state.sh"
# shellcheck source=/dev/null
. "$ROOT_DIR/Linux/.join-to-domain/lib/cleanup.sh"

MD_ETC_DIR="$TMP_ROOT/etc/MultiDirectory"
MD_STATE_DIR="$MD_ETC_DIR/state"
MD_BACKUPS_ROOT="$MD_ETC_DIR/backups"
MD_JOIN_ENV="$MD_STATE_DIR/join.env"
MD_PENDING_BACKUP="$MD_STATE_DIR/active-backup"
MD_ORIGINAL_BACKUP="$MD_STATE_DIR/original-backup"
MD_TRANSACTION_STATE="$MD_STATE_DIR/transaction.env"
MD_ROLLBACK_MARKER="$MD_STATE_DIR/rollback-in-progress"
LOG_FILE="$TMP_ROOT/join.log"
SYSTEM_FILE="$TMP_ROOT/etc/example.conf"

[[ "$(sanitize_input $'old\177\177\177new')" == "new" ]]
[[ "$(sanitize_input $'abc\b\bZ')" == "aZ" ]]

managed_join_paths() { printf '%s\n' "$SYSTEM_FILE"; }
is_redos_or_rhel_like() { return 1; }

mkdir -p "$(dirname "$SYSTEM_FILE")"
printf 'original\n' > "$SYSTEM_FILE"

create_join_backup
validate_join_backup
FIRST_BACKUP="$MD_BACKUP_DIR"
[[ "$(<"$MD_PENDING_BACKUP")" == "$FIRST_BACKUP" ]]

write_transaction_state JOIN_IN_PROGRESS join
grep -q '^STATE=JOIN_IN_PROGRESS$' "$MD_TRANSACTION_STATE"
grep -q '^OPERATION=join$' "$MD_TRANSACTION_STATE"

publish_original_backup "$FIRST_BACKUP"
[[ "$(<"$MD_ORIGINAL_BACKUP")" == "$FIRST_BACKUP" ]]

rm -f "$MD_JOIN_ENV"
MD_BACKUP_DIR=""
MD_MANIFEST=""
load_prejoin_backup
[[ "$MD_BACKUP_DIR" == "$FIRST_BACKUP" ]]
validate_join_backup
[[ "$(original_backup_manifest)" == "$FIRST_BACKUP/manifest.env" ]]
[[ "$(authoritative_domain_manifest)" == "$FIRST_BACKUP/manifest.env" ]]

# A later Join snapshot must never replace the immutable original pointer.
sleep 1
create_backup_set join
SECOND_BACKUP="$MD_BACKUP_DIR"
[[ "$SECOND_BACKUP" != "$FIRST_BACKUP" ]]
if publish_original_backup "$SECOND_BACKUP"; then
  printf 'original backup pointer was overwritten\n' >&2
  exit 1
fi
[[ "$(<"$MD_ORIGINAL_BACKUP")" == "$FIRST_BACKUP" ]]

# A partial state without state/backup is recoverable conservatively; an
# active transaction is handled by the normal transactional rollback instead.
rm -f "$MD_PENDING_BACKUP" "$MD_ORIGINAL_BACKUP" "$MD_JOIN_ENV"
DETECTED_DOMAIN_STATE=partial_join
partial_without_recovery_metadata
printf '%s\n' "$FIRST_BACKUP" > "$MD_PENDING_BACKUP"
if partial_without_recovery_metadata; then
  printf 'active transaction was misclassified as metadata-free\n' >&2
  exit 1
fi

# Failed rollback must retain every recovery marker for the next process.
MD_BACKUP_DIR="$FIRST_BACKUP"
MD_MANIFEST="$FIRST_BACKUP/manifest.env"
write_state_pointer "$MD_PENDING_BACKUP" "$FIRST_BACKUP"
write_transaction_state JOIN_IN_PROGRESS join
touch "$MD_ROLLBACK_MARKER"
warn() { :; }
activity_start() { :; }
activity_stop() { :; }
user_ok() { :; }
ui_text() { printf '%s' "$1"; }
perform_local_rollback_cleanup() { return 1; }
if rollback_local_changes 42; then
  printf 'failed rollback unexpectedly reported success\n' >&2
  exit 1
fi
[[ -f "$MD_PENDING_BACKUP" ]]
[[ -f "$MD_TRANSACTION_STATE" ]]
[[ -f "$MD_ROLLBACK_MARKER" ]]
grep -q '^STATE=ROLLBACK_IN_PROGRESS$' "$MD_TRANSACTION_STATE"

# Once verification/cleanup succeeds, only then may transaction metadata go.
perform_local_rollback_cleanup() { return 0; }
rollback_local_changes 42
[[ ! -e "$MD_STATE_DIR" ]]

# Emergency cleanup follows the same rule: metadata is finalized last.
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
if safe_leave_domain; then
  printf 'failed emergency cleanup unexpectedly reported success\n' >&2
  exit 1
fi
[[ -f "$MD_TRANSACTION_STATE" ]]

cleanup_domain_runtime_state() { return 0; }
safe_leave_domain
[[ ! -e "$MD_TRANSACTION_STATE" ]]

printf 'recovery state tests: OK\n'
