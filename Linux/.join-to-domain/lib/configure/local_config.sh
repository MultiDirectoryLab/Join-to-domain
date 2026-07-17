build_sssd_conf() {
  need_dir "$SSSD_CONF_D_SRC"
  need_file "$DEFAULT_SSSD_SRC"

  mkdir -p /etc/sssd
  chmod 700 /etc/sssd

  md_backup_once /etc/sssd/sssd.conf

  if [[ -d /etc/sssd/conf.d ]]; then
    md_backup_once /etc/sssd/conf.d
    if is_astra_se; then
      log "Astra SE detected: preserving existing SSSD snippets in /etc/sssd/conf.d"
    else
      rm -rf /etc/sssd/conf.d
      log "Removed old SSSD snippets from /etc/sssd/conf.d"
    fi
  fi

  mkdir -p /etc/sssd/conf.d
  chown root:root /etc/sssd/conf.d
  chmod 700 /etc/sssd/conf.d

  cp "$DEFAULT_SSSD_SRC" /etc/sssd/sssd.conf
  apply_placeholders_to_file /etc/sssd/sssd.conf

  chown root:root /etc/sssd/sssd.conf
  chmod 600 /etc/sssd/sssd.conf
  chmod 700 /etc/sssd

  md_track /etc/sssd/sssd.conf

  disable_sssd_socket_activation_if_needed

  log "Built SSSD config from template: ${DEFAULT_SSSD_SRC}"
  if is_astra_se; then
    log "Astra SE detected: SSSD conf.d preserved: /etc/sssd/conf.d"
  else
    log "SSSD conf.d kept empty: /etc/sssd/conf.d"
  fi
}

pam_has_module() {
  local file="$1"
  local module="$2"

  [[ -f "$file" ]] || return 1
  grep -Eq "^[[:space:]]*[^#].*[[:space:]]${module}([[:space:]]|$)" "$file" 2>/dev/null
}

pam_insert_before_first_module() {
  local file="$1"
  local anchor_module="$2"
  local line="$3"
  local tmp

  [[ -f "$file" ]] || die "PAM file not found: ${file}"

  tmp="$(mktemp)"
  awk -v anchor="${anchor_module}" -v insert_line="${line}" '
    BEGIN { inserted=0 }
    inserted == 0 && $0 !~ /^[[:space:]]*#/ && $0 ~ ("[[:space:]]" anchor "([[:space:]]|$)") {
      print insert_line
      inserted=1
    }
    { print }
    END {
      if (inserted == 0) {
        print insert_line
      }
    }
  ' "$file" > "$tmp" || {
    rm -f "$tmp"
    die "Failed to patch PAM file: ${file}"
  }

  cat "$tmp" > "$file"
  rm -f "$tmp"
}

pam_append_if_missing() {
  local file="$1"
  local module="$2"
  local line="$3"

  pam_has_module "$file" "$module" && return 0

  md_backup_once "$file"
  pam_insert_before_first_module "$file" pam_deny.so "$line"
  md_track "$file"
  log "Patched PAM file: ${file} (${module})"
}

patch_pam_before_if_missing() {
  local file="$1"
  local module="$2"
  local anchor_module="$3"
  local line="$4"

  pam_has_module "$file" "$module" && return 0

  md_backup_once "$file"
  pam_insert_before_first_module "$file" "$anchor_module" "$line"
  md_track "$file"
  log "Patched PAM file: ${file} (${module})"
}

install_astra_se_pam_config() {
  log "Astra SE detected: preserving PARSEC-aware PAM stack"

  patch_pam_before_if_missing /etc/pam.d/common-auth pam_sss.so pam_unix.so \
    "auth sufficient                        pam_sss.so try_first_pass"
  patch_pam_before_if_missing /etc/pam.d/common-account pam_sss.so pam_unix.so \
    "account sufficient                      pam_sss.so"
  pam_append_if_missing /etc/pam.d/common-password pam_sss.so \
    "password [success=1 default=ignore]     pam_sss.so use_authtok"

  if ! pam_has_module /etc/pam.d/common-session pam_sss.so; then
    md_backup_once /etc/pam.d/common-session
    printf '%s\n' "session optional                        pam_sss.so" >> /etc/pam.d/common-session
    md_track /etc/pam.d/common-session
    log "Patched PAM file: /etc/pam.d/common-session (pam_sss.so)"
  fi

  if ! pam_has_module /etc/pam.d/common-session pam_mkhomedir.so; then
    md_backup_once /etc/pam.d/common-session
    printf '%s\n' "session optional                        pam_mkhomedir.so skel=/etc/skel umask=0022" >> /etc/pam.d/common-session
    md_track /etc/pam.d/common-session
    log "Patched PAM file: /etc/pam.d/common-session (pam_mkhomedir.so)"
  fi

  if ! pam_has_module /etc/pam.d/common-session pam_kiosk2.so; then
    die "Astra SE PAM safety check failed: /etc/pam.d/common-session lacks pam_kiosk2.so"
  fi

  log "Astra SE PAM stack preserved"
}

install_pam_config() {
  if is_redos_or_rhel_like; then
    if have_cmd authselect; then
      authselect select sssd with-mkhomedir --force || true
    fi

    systemctl enable --now oddjobd.service 2>/dev/null || true
    return 0
  fi

  if is_altlinux; then
    need_dir "$PAM_D_SRC"

    [[ -f "${PAM_D_SRC}/alt-system-auth" ]] && install_local_file "${PAM_D_SRC}/alt-system-auth" /etc/pam.d/system-auth 0644
    [[ -f "${PAM_D_SRC}/alt-su" ]] && install_local_file "${PAM_D_SRC}/alt-su" /etc/pam.d/su 0644
    [[ -f "${PAM_D_SRC}/alt-sshd" ]] && install_local_file "${PAM_D_SRC}/alt-sshd" /etc/pam.d/sshd 0644
    [[ -f "${PAM_D_SRC}/alt-gdm-password" && -f /etc/pam.d/gdm-password ]] && install_local_file "${PAM_D_SRC}/alt-gdm-password" /etc/pam.d/gdm-password 0644
    [[ -f "${PAM_D_SRC}/alt-login" && -f /etc/pam.d/login ]] && install_local_file "${PAM_D_SRC}/alt-login" /etc/pam.d/login 0644
    [[ -f "${PAM_D_SRC}/alt-common-login" && -f /etc/pam.d/common-login ]] && install_local_file "${PAM_D_SRC}/alt-common-login" /etc/pam.d/common-login 0644

    chmod 4711 /usr/bin/sudo 2>/dev/null || true
    return 0
  fi

  if is_astra_se; then
    install_astra_se_pam_config
    return 0
  fi

  if is_deb_based; then
    if [[ -d "$PAM_D_SRC" ]]; then
      [[ -f "${PAM_D_SRC}/common-auth" ]] && install_local_file "${PAM_D_SRC}/common-auth" /etc/pam.d/common-auth 0644
      [[ -f "${PAM_D_SRC}/common-account" ]] && install_local_file "${PAM_D_SRC}/common-account" /etc/pam.d/common-account 0644
      [[ -f "${PAM_D_SRC}/common-session" ]] && install_local_file "${PAM_D_SRC}/common-session" /etc/pam.d/common-session 0644
      [[ -f "${PAM_D_SRC}/common-password" ]] && install_local_file "${PAM_D_SRC}/common-password" /etc/pam.d/common-password 0644
    else
      pam-auth-update --enable mkhomedir || true
    fi
  fi
}

install_accountsservice_cache_helper() {
  [[ -f "$ACCOUNTSERVICE_HELPER_SRC" ]] || return 0

  install_local_file "$ACCOUNTSERVICE_HELPER_SRC" "$ACCOUNTSERVICE_HELPER_DST" 0755
}

install_profile_config() {
  [[ -d "$PROFILE_D_SRC" ]] || return 0

  copy_dir_files "$PROFILE_D_SRC" /etc/profile.d 0644
}

patch_nsswitch_database() {
  local db="$1"
  local service="$2"
  local file=/etc/nsswitch.conf
  local tmp

  [[ -f "$file" ]] || die "NSS configuration not found: ${file}"

  tmp="$(mktemp)"
  awk -v db="${db}" -v service="${service}" '
    BEGIN { changed=0 }
    $0 ~ "^[[:space:]]*" db ":" {
      if ($0 !~ ("(^|[[:space:]])" service "([[:space:]]|$)")) {
        print $0 " " service
      } else {
        print
      }
      changed=1
      next
    }
    { print }
    END {
      if (changed == 0) {
        printf "%s: files %s\n", db, service
      }
    }
  ' "$file" > "$tmp" || {
    rm -f "$tmp"
    die "Failed to patch ${file}"
  }

  cat "$tmp" > "$file"
  rm -f "$tmp"
}

remove_nsswitch_database_service() {
  local db="$1"
  local service="$2"
  local file=/etc/nsswitch.conf
  local tmp

  [[ -f "$file" ]] || die "NSS configuration not found: ${file}"

  tmp="$(mktemp)"
  awk -v db="${db}" -v service="${service}" '
    $0 ~ "^[[:space:]]*" db ":" {
      out = $1
      kept = 0
      for (i = 2; i <= NF; i++) {
        if ($i == service) {
          continue
        }
        out = out " " $i
        kept = 1
      }
      if (kept == 0) {
        out = out " files"
      }
      print out
      next
    }
    { print }
  ' "$file" > "$tmp" || {
    rm -f "$tmp"
    die "Failed to patch ${file}"
  }

  cat "$tmp" > "$file"
  rm -f "$tmp"
}

install_nsswitch_config() {
  if ! is_astra_se; then
    install_local_file "$NSSWITCH_SRC" /etc/nsswitch.conf 0644
    return 0
  fi

  log "Astra SE detected: patching /etc/nsswitch.conf without replacing it"
  md_backup_once /etc/nsswitch.conf

  patch_nsswitch_database passwd sss
  patch_nsswitch_database group sss
  patch_nsswitch_database shadow sss
  remove_nsswitch_database_service sudoers sss
  patch_nsswitch_database netgroup sss
  patch_nsswitch_database automount sss

  chmod 0644 /etc/nsswitch.conf
  md_track /etc/nsswitch.conf
  log "Patched NSS configuration: /etc/nsswitch.conf"
}

install_static_configs() {
  log "Installing config files"

  install_local_file "$KRB5_SRC" /etc/krb5.conf 0644
  apply_placeholders_to_file /etc/krb5.conf

  install_nsswitch_config

  mkdir -p /etc/ssh/sshd_config.d
  install_local_file "$SSH_MD_SRC" /etc/ssh/sshd_config.d/ssh_md.conf 0644

  build_sssd_conf
  install_accountsservice_cache_helper
  install_profile_config
  install_pam_config

  if [[ -d "$SUDOERS_D_SRC" ]]; then
    mkdir -p /etc/sudoers.d
    copy_dir_files "$SUDOERS_D_SRC" /etc/sudoers.d 0440
    apply_placeholders_in_dir /etc/sudoers.d
    find /etc/sudoers.d -type f -exec chmod 0440 {} \; 2>/dev/null || true
    validate_sudoers
  fi

  if [[ -d "$RESOLVED_CONF_D_SRC" ]]; then
    mkdir -p /etc/systemd/resolved.conf.d
    copy_dir_files "$RESOLVED_CONF_D_SRC" /etc/systemd/resolved.conf.d 0644
    apply_placeholders_in_dir /etc/systemd/resolved.conf.d
  fi

  if [[ "${WITH_SALT:-0}" -eq 1 ]]; then
    if [[ -d "$SALT_SRC" ]]; then
      mkdir -p /etc/salt
      copy_dir_files "$SALT_SRC" /etc/salt 0644
      apply_placeholders_in_dir /etc/salt
    fi

    # install_salt_custom_modules
  else
    log "Community edition: Salt config files are skipped"
  fi
}

create_computer_object_if_needed() {
  local computer_dn exists_dn exists_uac search_resp add_resp add_http add_body

  computer_dn="cn=${HOSTNAME},${LDAP_COMPUTER_OU}"
  COMPUTER_DN="$computer_dn"

  log "Checking whether computer cn=${HOSTNAME} exists"

  search_resp="$(
    api_search "${access_token}" "${LDAP_COMPUTER_OU}" 2 "(&(objectClass=computer)(cn=${HOSTNAME}))" "[\"cn\",\"userAccountControl\"]"
  )" || die "Failed to check whether computer object exists in LDAP"

  exists_dn="$(
    printf '%s' "$search_resp" \
      | jq -r '.search_result[0].object_name // empty' 2>/dev/null || true
  )"
  exists_uac="$(
    printf '%s' "$search_resp" \
      | jq -r '.search_result[0].partial_attributes[]? | select(.type=="userAccountControl") | .vals[0] // empty' 2>/dev/null || true
  )"

  if [[ -n "${exists_dn}" ]]; then
    warn "Computer already exists in LDAP: ${exists_dn}. Creating will be skipped."
    COMPUTER_DN="$exists_dn"
    enable_computer_account_if_disabled "${exists_dn}" "${exists_uac}"
    return 0
  fi

  log "Creating computer object: ${computer_dn}"

  add_resp="$(
    curl -sS -w "\n%{http_code}" \
      --connect-timeout "${API_CONNECT_TIMEOUT}" \
      --max-time "${API_MAX_TIME}" \
      -X POST "https://${API_HOST}/api/entry/add" \
      -H 'accept: application/json' \
      -H 'Content-Type: application/json' \
      -H "Cookie: id=${access_token}" \
      -d "{
        \"entry\": \"${computer_dn}\",
        \"attributes\": [
          { \"type\": \"objectClass\", \"vals\": [\"top\", \"computer\"] },
          { \"type\": \"description\", \"vals\": [\"\"] }
        ]
      }" 2>&1
  )" || true

  add_http="$(echo "$add_resp" | tail -n1)"
  add_body="$(echo "$add_resp" | sed '$d')"

  if [[ ! "$add_http" =~ ^2[0-9][0-9]$ ]]; then
    die "Failed to create computer object ${computer_dn}. HTTP ${add_http}: ${add_body}"
  fi

  log "Computer object created: ${computer_dn}"
  enable_computer_account "${computer_dn}"
}

validate_keytab() {
  log "Checking keytab"

  klist -k /etc/krb5.keytab || die "Invalid keytab"

  if kinit -k "host/${FQDN}@${REALM}"; then
    log "Kerberos authentication succeeded: host/${FQDN}@${REALM}"
    kdestroy || true
    return 0
  fi

  if kinit -k "host/${HOSTNAME}@${REALM}"; then
    log "Kerberos authentication succeeded: host/${HOSTNAME}@${REALM}"
    kdestroy || true
    return 0
  fi

  die "Kerberos keytab authentication failed"
}

ldap_uri_host() {
  local uri="$1"
  local host

  host="${uri#ldap://}"
  host="${host#ldaps://}"
  host="${host%%/*}"
  if [[ "$host" == \[*\] ]]; then
    host="${host#[}"
    host="${host%%]*}"
  else
    host="${host%%:*}"
  fi

  printf '%s' "$host"
}

validate_ldap_uri_uses_fqdn() {
  local host

  host="$(ldap_uri_host "${URI}")"

  [[ -n "$host" ]] || die "LDAP URI is invalid: ${URI}"

  if [[ "$host" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || [[ "$host" == *":"* ]]; then
    die "LDAP URI must use FQDN, not IP address: ${URI}. IP-based Kerberos SPNs such as ldap/${host}@${REALM} are not supported."
  fi

  if [[ "$host" != "${DOMAIN}" && "$host" != "${FQDN}" ]]; then
    warn "LDAP URI host is ${host}; expected ${DOMAIN} or ${FQDN} to avoid Kerberos SPN mismatch"
  fi
}

validate_ldap_gssapi_auth() {
  local ldap_client_conf="/tmp/md-ldap-gssapi.conf"

  log "Checking LDAP GSSAPI authentication"

  validate_ldap_uri_uses_fqdn

  if ! kinit -k "host/${FQDN}@${REALM}"; then
    die "Kerberos GSSAPI initialization failed: host/${FQDN}@${REALM}"
  fi

  cat > "$ldap_client_conf" <<EOF
SASL_NOCANON on
URI ${URI}
BASE ${LDAP_BASE_DN}
EOF

  LDAPCONF="$ldap_client_conf" ldapwhoami -Y GSSAPI -H "${URI}" >/dev/null \
    || {
      rm -f "$ldap_client_conf"
      kdestroy || true
      die "LDAP GSSAPI authentication failed"
    }

  log "LDAP GSSAPI authentication succeeded"

  rm -f "$ldap_client_conf"
  kdestroy || true
}

astra_parsec_sssd_package_list() {
  printf '%s\n' \
    libparsec-db-sssd3 \
    libparsec-mac-db-sssd3 \
    libparsec-mic-db-sssd3 \
    libparsec-aud-db-sssd3 \
    libparsec-cap-db-sssd3 \
    sssd-dbus
}

astra_parsec_sssd_packages_installed() {
  local package

  while IFS= read -r package; do
    [[ -n "$package" ]] || continue
    dpkg-query -W -f='${Status}' "$package" 2>/dev/null | grep -q "install ok installed" || return 1
  done < <(astra_parsec_sssd_package_list)
}

astra_parsec_core_installed() {
  dpkg-query -W -f='${Status}' libparsec-base3 2>/dev/null | grep -q "install ok installed"
}

diagnose_missing_astra_parsec_mswitch() {
  local file=/etc/parsec/mswitch.conf

  warn "PARSEC configuration file '${file}' was not found."
  warn "No supported alternative PARSEC switch configuration is documented for this Astra Linux release."

  if astra_parsec_core_installed; then
    warn "PARSEC core package 'libparsec-base3' is installed, but its switch configuration is absent."
    warn "Restore '${file}' using the Astra Linux package or supported domain-client configuration for this release."
  else
    warn "PARSEC core component is unavailable: package 'libparsec-base3' is not installed."
    warn "Install the Astra Linux SE PARSEC components for this release before enabling PARSEC/SSSD integration."
  fi

  warn "Skipping PARSEC-specific SSSD integration; standard SSSD domain integration will continue."
}

astra_parsec_mswitch_available() {
  local file=/etc/parsec/mswitch.conf

  if [[ ! -e "$file" ]]; then
    diagnose_missing_astra_parsec_mswitch
    return 1
  fi

  [[ -f "$file" ]] || die "Unsupported PARSEC configuration: ${file} is not a regular file"
  [[ -r "$file" ]] || die "PARSEC configuration is not readable: ${file}"
  [[ -w "$file" ]] || die "PARSEC configuration is not writable: ${file}"
}

install_astra_parsec_sssd_packages() {
  local package missing=()

  while IFS= read -r package; do
    [[ -n "$package" ]] || continue
    if ! dpkg-query -W -f='${Status}' "$package" 2>/dev/null | grep -q "install ok installed"; then
      missing+=("$package")
    fi
  done < <(astra_parsec_sssd_package_list)

  if (( ${#missing[@]} == 0 )); then
    log "Astra SE PARSEC/SSSD packages are installed"
    return 0
  fi

  log "Installing Astra SE PARSEC/SSSD packages: ${missing[*]}"
  apt-get update || die "Failed to update package index before installing Astra SE PARSEC/SSSD packages"
  apt-get install -y "${missing[@]}" || die "Failed to install Astra SE PARSEC/SSSD packages"

  astra_parsec_sssd_packages_installed || die "Astra SE PARSEC/SSSD packages are still missing after installation"
}

backup_timestamped_file() {
  local path="$1"
  local backup=""

  if [[ -f "$path" ]]; then
    backup="${path}.bak.$(date +%F_%H-%M-%S)"
    cp "$path" "$backup"
    log "Backup created: ${backup}"
  fi

  printf '%s' "$backup"
}

write_astra_parsec_sssd_conf() {
  need_file "$ASTRA_PARSEC_SSSD_SRC"
  mkdir -p /etc/sssd
  chmod 700 /etc/sssd

  cp "$ASTRA_PARSEC_SSSD_SRC" /etc/sssd/sssd.conf
  apply_placeholders_to_file /etc/sssd/sssd.conf
  chown root:root /etc/sssd/sssd.conf
  chmod 600 /etc/sssd/sssd.conf
  md_track /etc/sssd/sssd.conf

  log "Astra SE SSSD configuration written: /etc/sssd/sssd.conf"
}

set_parsec_mswitch_db() {
  local db="$1"
  local source="$2"
  local file=/etc/parsec/mswitch.conf
  local tmp

  tmp="$(mktemp)"
  awk -v db="${db}" -v source="${source}" '
    BEGIN { changed=0 }
    $0 ~ "^[[:space:]]*" db ":" {
      if (changed == 0) {
        printf "%s: %s\n", db, source
      }
      changed=1
      next
    }
    { print }
    END {
      if (changed == 0) {
        printf "%s: %s\n", db, source
      }
    }
  ' "$file" > "$tmp" || {
    rm -f "$tmp"
    die "Failed to patch ${file}"
  }

  cat "$tmp" > "$file"
  rm -f "$tmp"
}

configure_astra_parsec_mswitch() {
  local file=/etc/parsec/mswitch.conf

  [[ -f "$file" ]] || die "PARSEC switch configuration disappeared during configuration: ${file}"

  backup_timestamped_file "$file" >/dev/null

  set_parsec_mswitch_db mac sssd
  set_parsec_mswitch_db audit sssd
  set_parsec_mswitch_db mic sssd

  md_track "$file"
  log "Astra SE PARSEC mswitch configured: ${file}"
}

restart_astra_parsec_sssd_or_rollback() {
  local sssd_backup="$1"

  sss_cache -E 2>/dev/null || true

  if systemctl restart sssd; then
    log "SSSD restarted"
    return 0
  fi

  warn "SSSD restart failed after Astra SE PARSEC configuration"

  if [[ -n "$sssd_backup" && -f "$sssd_backup" ]]; then
    cp "$sssd_backup" /etc/sssd/sssd.conf
    chmod 600 /etc/sssd/sssd.conf
    systemctl restart sssd 2>/dev/null || true
    die "SSSD failed to start. Restored /etc/sssd/sssd.conf from ${sssd_backup}"
  fi

  rm -f /etc/sssd/sssd.conf
  die "SSSD failed to start. Removed generated /etc/sssd/sssd.conf because no backup existed."
}

validate_astra_parsec_sssd_config_or_rollback() {
  local sssd_backup="$1"

  validate_no_password_based_sssd_auth

  if have_cmd sssctl; then
    if sssctl config-check; then
      return 0
    fi

    if [[ -n "$sssd_backup" && -f "$sssd_backup" ]]; then
      cp "$sssd_backup" /etc/sssd/sssd.conf
      chmod 600 /etc/sssd/sssd.conf
      die "Generated Astra SE SSSD configuration is invalid. Restored /etc/sssd/sssd.conf from ${sssd_backup}"
    fi

    rm -f /etc/sssd/sssd.conf
    die "Generated Astra SE SSSD configuration is invalid. Removed generated /etc/sssd/sssd.conf because no backup existed."
  fi

  warn "sssctl not found, SSSD config validation skipped"
}

configure_astra_se_parsec_sssd() {
  local sssd_backup

  is_astra_se || return 0

  log "Astra Linux SE detected: checking PARSEC/SSSD integration"

  if ! astra_parsec_mswitch_available; then
    return 0
  fi

  install_astra_parsec_sssd_packages

  sssd_backup="$(backup_timestamped_file /etc/sssd/sssd.conf)"
  write_astra_parsec_sssd_conf
  validate_astra_parsec_sssd_config_or_rollback "$sssd_backup"

  configure_astra_parsec_mswitch
  restart_astra_parsec_sssd_or_rollback "$sssd_backup"
}
