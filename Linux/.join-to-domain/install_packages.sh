#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_LIB_DIR="${SCRIPT_DIR}/lib/install"
INSTALL_MODULES=(
  common
  edition_state
  package_db
  local_packages
  installers
  removal
  flow
)

validate_install_modules() {
  local module
  local path
  local missing=0

  for module in "${INSTALL_MODULES[@]}"; do
    path="${INSTALL_LIB_DIR}/${module}.sh"

    if [[ ! -f "$path" ]]; then
      if [[ "$missing" -eq 0 ]]; then
        printf '[ERR] %s\n' "$(ui_text "Missing required install modules:" "Отсутствуют обязательные модули установки:")" >&2
      fi

      printf '  - %s: %s\n' "$module" "$path" >&2
      missing=1
    fi
  done

  return "$missing"
}

source_install_module() {
  local module="$1"
  local path="${INSTALL_LIB_DIR}/${module}.sh"

  if [[ ! -f "$path" ]]; then
    printf '[ERR] %s: %s\n' "$(ui_text "Required install module not found" "Не найден обязательный модуль установки")" "$module" >&2
    printf '[ERR] %s: %s\n' "$(ui_text "Expected path" "Ожидаемый путь")" "$path" >&2
    return 1
  fi

  . "$path"
}

export JOIN_TO_DOMAIN_INTERNAL_DIR="$SCRIPT_DIR"

. "${SCRIPT_DIR}/lib/translations.sh"

validate_install_modules

for module in "${INSTALL_MODULES[@]}"; do
  source_install_module "$module"
done

main "$@"
