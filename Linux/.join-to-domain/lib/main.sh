#!/usr/bin/env bash
set -uo pipefail

JOIN_TO_DOMAIN_LIB_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

source_join_module() {
  local module="$1"
  local path="${JOIN_TO_DOMAIN_LIB_DIR}/${module}.sh"

  if [[ ! -f "$path" ]]; then
    printf '[ERROR] Required internal module not found: %s\n' "$module" >&2
    return 1
  fi

  . "$path"
}

source_join_module common || { return 1 2>/dev/null || exit 1; }
source_join_module i18n || { return 1 2>/dev/null || exit 1; }
source_join_module dependencies || { return 1 2>/dev/null || exit 1; }
source_join_module domain_state || { return 1 2>/dev/null || exit 1; }
source_join_module cleanup || { return 1 2>/dev/null || exit 1; }
source_join_module flow || { return 1 2>/dev/null || exit 1; }

main() {
  load_env_file
  parse_args "$@"
  setup_logging
  select_ui_language
  main_menu
}
