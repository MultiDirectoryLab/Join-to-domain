#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CONFIGURE_LIB_DIR="${SCRIPT_DIR}/lib/configure"

source_configure_module() {
  local module="$1"
  local path="${CONFIGURE_LIB_DIR}/${module}.sh"

  if [[ ! -f "$path" ]]; then
    printf '[ERR] Required configure module not found: %s\n' "$module" >&2
    return 1
  fi

  . "$path"
}

export JOIN_TO_DOMAIN_INTERNAL_DIR="$SCRIPT_DIR"

source_configure_module common
source_configure_module templates
source_configure_module identity_dns
source_configure_module state
source_configure_module api
source_configure_module validation
source_configure_module local_config
source_configure_module salt
source_configure_module leave
source_configure_module flow

main "$@"
