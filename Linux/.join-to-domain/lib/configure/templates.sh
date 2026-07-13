validate_non_empty_conf_dir() {
  local dir="$1"

  need_dir "$dir"

  shopt -s nullglob
  local files=("${dir}"/*.conf)
  shopt -u nullglob

  if (( ${#files[@]} == 0 )); then
    [[ "$dir" == "$SCRIPT_DIR"* ]] && die "Required internal configuration files not found"
    die "No .conf files found in ${dir}"
  fi
}

validate_files_structure() {
  need_dir "$FILES_DIR"
  need_file "$KRB5_SRC"
  need_file "$NSSWITCH_SRC"
  need_file "$SSH_MD_SRC"
  need_dir "$SSSD_CONF_D_SRC"
  need_file "$DEFAULT_SSSD_SRC"
  if is_astra_se; then
    need_file "$ASTRA_PARSEC_SSSD_SRC"
  fi
  need_dir "$PAM_D_SRC"

  if [[ "${WITH_SALT:-0}" -eq 1 ]]; then
    need_dir "$SALT_SRC"
    need_file "$MD_GPUPDATE_SRC"

    if [[ -f "$SALT_PKG_MODULE_SRC" ]]; then
      need_file "$SALT_PKG_MODULE_SRC"
    else
      warn "Custom Salt module not found, pkg.py install will be skipped: ${SALT_PKG_MODULE_SRC}"
    fi
  fi

  validate_template_placeholder_coverage
}

is_supported_template_placeholder() {
  case "$1" in
    __DOMAIN__|__REALM__|__KDC__|__KADMIN__|__URI__|\
__LDAP_SEARCH_BASE__|__LDAP_USER_BASE__|__LDAP_GROUP_BASE__|\
__HOSTNAME__|__FQDN__|__LDAP_COMPUTER_OU__|__SALT_MASTER__|\
__MD_DNS_SERVER__)
      return 0
      ;;
    __SALT_MASTER_FINGER__)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

validate_template_placeholder_coverage() {
  local placeholder failed=0

  while IFS= read -r placeholder; do
    [[ -n "$placeholder" ]] || continue
    if ! is_supported_template_placeholder "$placeholder"; then
      warn "Unsupported template placeholder found: ${placeholder}"
      failed=1
    fi
  done < <(grep -RhoE '__[A-Z0-9_]+__' "$FILES_DIR" 2>/dev/null | sort -u || true)

  if [[ "$failed" -ne 0 ]]; then
    die "Template placeholder coverage validation failed"
  fi
}

apply_placeholders_to_file() {
  local file="$1"

  [[ -f "$file" ]] || return 0

  sed -i \
    -e "s/__DOMAIN__/${DOMAIN}/g" \
    -e "s/__REALM__/${REALM}/g" \
    -e "s/__KDC__/${KDC}/g" \
    -e "s/__KADMIN__/${KADMIN}/g" \
    -e "s#__URI__#${URI}#g" \
    -e "s#__LDAP_SEARCH_BASE__#${LDAP_SEARCH_BASE}#g" \
    -e "s#__LDAP_USER_BASE__#${LDAP_USER_BASE}#g" \
    -e "s#__LDAP_GROUP_BASE__#${LDAP_GROUP_BASE}#g" \
    -e "s/__HOSTNAME__/${HOSTNAME}/g" \
    -e "s/__FQDN__/${FQDN}/g" \
    -e "s#__LDAP_COMPUTER_OU__#${LDAP_COMPUTER_OU}#g" \
    -e "s/__SALT_MASTER__/${SALT_MASTER:-}/g" \
    -e "s/__MD_DNS_SERVER__/${MD_DNS_SERVER:-}/g" \
    "$file"

  if grep -En '__[A-Z0-9_]+__' "$file" >/tmp/md-template-placeholders.matches 2>/dev/null; then
    warn "Unresolved template placeholders found in ${file}:"
    cat /tmp/md-template-placeholders.matches || true
    die "Template rendering failed for ${file}"
  fi
}

apply_placeholders_in_dir() {
  local dir="$1"

  [[ -d "$dir" ]] || return 0

  while IFS= read -r -d '' file_path; do
    [[ -f "$file_path" ]] || continue
    apply_placeholders_to_file "$file_path"
  done < <(find "$dir" -type f -print0)
}
