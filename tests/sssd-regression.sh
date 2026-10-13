#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
TEST_LIB_DIR="${SCRIPT_DIR}/../linux/.join-to-domain/lib"
tmp_root="$(mktemp -d)"
trap 'rm -rf -- "$tmp_root"' EXIT

run_scenario() (
  scenario="$1"
  . "$TEST_LIB_DIR/configure/common.sh"
  . "$TEST_LIB_DIR/configure/state.sh"
  . "$TEST_LIB_DIR/configure/validation.sh"
  . "$TEST_LIB_DIR/configure/leave.sh"

  MD_STATE_DIR="$tmp_root/$scenario/state"
  MD_JOIN_ENV="$MD_STATE_DIR/join.env"
  MD_TRANSACTION_STATE="$MD_STATE_DIR/transaction.env"
  MD_ROLLBACK_MARKER="$MD_STATE_DIR/rollback-in-progress"
  MD_PENDING_BACKUP="$MD_STATE_DIR/active-backup"
  MD_MANIFEST="$tmp_root/$scenario/manifest.env"
  LOG_FILE="$tmp_root/$scenario/join.log"
  DOMAIN=md.test
  WITH_SALT=0
  mkdir -p "$MD_STATE_DIR"
  printf 'backup\n' > "$MD_PENDING_BACKUP"
  printf 'original\n' > "$tmp_root/$scenario/original"
  printf 'changed\n' > "$tmp_root/$scenario/current"
  : > "$MD_MANIFEST"

  log() { :; }
  warn() { :; }
  ok() { :; }
  activity_stop() { :; }
  activity_start() { :; }
  user_ok() { :; }
  ui_text() { printf '%s' "$1"; }
  report_unexpected_join_failure() { :; }
  is_altlinux() { return 0; }
  have_cmd() { [[ "$scenario" != missing-tools ]]; }
  find_executable() { return 1; }
  sleep() { :; }
  # Trigger the actual ERR handler/local rollback with controlled failures.
  die() { printf '%s\n' "$*" >> "$LOG_FILE"; return 1; }
  perform_local_rollback_cleanup() {
    cp "$tmp_root/$scenario/original" "$tmp_root/$scenario/current"
    touch "$tmp_root/$scenario/rolled-back"
  }
  systemctl() {
    printf '%s\n' "$*" >> "$LOG_FILE"
    case "$1" in
      daemon-reload) [[ "$scenario" != daemon-reload ]];;
      enable) [[ "$scenario" != enable ]];;
      restart) [[ "$scenario" != restart ]];;
      is-active) [[ "$scenario" != inactive ]];;
      show)
        printf 'ActiveState=active\nSubState=running\n'
        if [[ "$scenario" == failed-result ]]; then
          printf 'Result=exit-code\n'
        else
          printf 'Result=success\n'
        fi
        ;;
      *) return 1;;
    esac
  }
  sssctl() {
    printf '%s\n' "$*" >> "$LOG_FILE"
    case "$1" in
      config-check) [[ "$scenario" != config ]];;
      domain-list)
        if [[ "$scenario" == wrong-domain ]]; then printf 'other.test\n'; else printf '%s\n' "$DOMAIN"; fi
        ;;
      domain-status)
        if [[ "$scenario" == offline ]]; then printf 'Online status: Offline\n'; else printf 'Online status: Online\n'; fi
        ;;
      *) return 1;;
    esac
  }

  MD_JOIN_ROLLBACK_ACTIVE=1
  trap on_join_error ERR
  start_services
  printf 'DOMAIN=md.test\n' > "$MD_JOIN_ENV"
  MD_JOIN_ROLLBACK_ACTIVE=0
  trap - ERR
)

for scenario in missing-tools config daemon-reload enable restart inactive failed-result wrong-domain offline; do
  # Do not put the tested function in an if/! context: that suppresses errexit
  # and ERR throughout nested functions, unlike the real configure launcher.
  set +e
  (set -Ee; run_scenario "$scenario")
  status=$?
  set -e
  [[ "$status" -ne 0 ]]
  [[ ! -f "$tmp_root/$scenario/state/join.env" ]]
  [[ -f "$tmp_root/$scenario/rolled-back" ]]
  cmp "$tmp_root/$scenario/original" "$tmp_root/$scenario/current"
done

run_scenario success
[[ -f "$tmp_root/success/state/join.env" ]]
[[ ! -f "$tmp_root/success/rolled-back" ]]

# Both transaction flows must validate services before persisting membership.
for file in flow.sh rejoin.sh; do
  awk '/^  start_services$/ { started=1 } /^  save_join_env$/ { if (!started) exit 1; found=1 } END { if (!found) exit 1 }' \
    "$TEST_LIB_DIR/configure/$file"
done
printf 'SSSD service/config/domain failure rollback tests: OK\n'
