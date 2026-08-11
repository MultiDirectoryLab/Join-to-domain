#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CONFIGURE_LIB_DIR="${SCRIPT_DIR}/lib/configure"

source_configure_module() {
  local module="$1"
  local path="${CONFIGURE_LIB_DIR}/${module}.sh"

  if [[ ! -f "$path" ]]; then
    if [[ "${MD_UI_LANG:-en}" == "ru" ]]; then
      printf '[ОШИБКА] Не найден обязательный модуль настройки: %s\n' "$module" >&2
    else
      printf '[ERR] Required configure module not found: %s\n' "$module" >&2
    fi
    return 1
  fi

  . "$path"
}

export JOIN_TO_DOMAIN_INTERNAL_DIR="$SCRIPT_DIR"

source_configure_module common
. "${SCRIPT_DIR}/lib/translations.sh"
. "${SCRIPT_DIR}/lib/domain_state.sh"
source_configure_module templates
source_configure_module identity_dns
source_configure_module state
source_configure_module trust
source_configure_module api
source_configure_module validation
source_configure_module local_config
source_configure_module salt
source_configure_module leave
source_configure_module rejoin
source_configure_module flow

main "$@"
