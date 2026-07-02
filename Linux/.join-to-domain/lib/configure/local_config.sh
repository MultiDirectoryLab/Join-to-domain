build_sssd_conf() {
  need_dir "$SSSD_CONF_D_SRC"
  validate_non_empty_conf_dir "$SSSD_CONF_D_SRC"

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

  : > /etc/sssd/sssd.conf

  shopt -s nullglob
  local files=("${SSSD_CONF_D_SRC}"/*.conf)
  shopt -u nullglob

  local src
  for src in "${files[@]}"; do
    echo "# Source template: $(basename "$src")" >> /etc/sssd/sssd.conf
    cat "$src" >> /etc/sssd/sssd.conf
    echo >> /etc/sssd/sssd.conf
  done

  apply_placeholders_to_file /etc/sssd/sssd.conf

  chown root:root /etc/sssd/sssd.conf
  chmod 600 /etc/sssd/sssd.conf
  chmod 700 /etc/sssd

  md_track /etc/sssd/sssd.conf

  disable_sssd_socket_activation_if_needed

  log "Built single SSSD config: /etc/sssd/sssd.conf"
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
  patch_nsswitch_database sudoers sss
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

    install_salt_custom_modules
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
    curl -k -sS -w "\n%{http_code}" \
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
