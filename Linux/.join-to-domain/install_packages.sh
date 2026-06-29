#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_LIB_DIR="${SCRIPT_DIR}/lib/install"

source_install_module() {
  local module="$1"
  local path="${INSTALL_LIB_DIR}/${module}.sh"

  if [[ ! -f "$path" ]]; then
    printf '[ERR] Required install module not found: %s\n' "$module" >&2
    return 1
  fi

  . "$path"
}

export JOIN_TO_DOMAIN_INTERNAL_DIR="$SCRIPT_DIR"

source_install_module common
source_install_module edition_state
source_install_module package_db
source_install_module local_packages
source_install_module installers
source_install_module removal
source_install_module flow

main "$@"
