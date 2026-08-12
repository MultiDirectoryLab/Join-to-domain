case "$-" in
  *i*) ;;
  *) return 0 2>/dev/null || exit 0 ;;
esac

if [ -n "${BASH_VERSION:-}" ]; then
  __md_update_prompt() {
    local md_status="$?"
    local md_prompt_user="${USER:-}"

    if [ -z "$md_prompt_user" ] && command -v id >/dev/null 2>&1; then
      md_prompt_user="$(id -un 2>/dev/null || true)"
    fi

    md_prompt_user="${md_prompt_user%%@*}"
    if [ -n "$md_prompt_user" ]; then
      PS1='\[\033[01;32m\]'"${md_prompt_user}"'@\H\[\033[00m\]:\[\033[01;34m\]\w\[\033[00m\]\$ '
    fi

    return "$md_status"
  }

  case ";${PROMPT_COMMAND:-};" in
    *";__md_update_prompt;"*) ;;
    *)
      PROMPT_COMMAND="__md_update_prompt${PROMPT_COMMAND:+; ${PROMPT_COMMAND}}"
      ;;
  esac

fi
