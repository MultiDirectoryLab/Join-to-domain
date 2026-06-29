#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
INTERNAL_DIR="${SCRIPT_DIR}/.join-to-domain"
MAIN_MODULE="${INTERNAL_DIR}/lib/main.sh"

if [[ ! -f "$MAIN_MODULE" ]]; then
  printf '[ERROR] Required internal component not found\n' >&2
  exit 1
fi

export JOIN_TO_DOMAIN_SCRIPT_DIR="$SCRIPT_DIR"
export JOIN_TO_DOMAIN_INTERNAL_DIR="$INTERNAL_DIR"

. "$MAIN_MODULE"

main "$@"
