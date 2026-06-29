valid_hostname() {
  local h="$1"
  [[ "$h" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]]
}

apply_hostname() {
  local new_short="$1"

  HOSTNAME="$new_short"
  FQDN="${HOSTNAME}.${DOMAIN}"

  log "Renaming host: ${HOSTNAME} (${FQDN})"

  md_backup_once /etc/hostname
  md_backup_once /etc/hosts

  if have_cmd hostnamectl; then
    hostnamectl set-hostname "$FQDN"
  else
    echo "$FQDN" > /etc/hostname
    hostname "$FQDN" || true
  fi

  if [[ -f /etc/hosts ]]; then
    if grep -qE '^\s*127\.0\.1\.1\s+' /etc/hosts; then
      sed -i -E "s/^\s*127\.0\.1\.1\s+.*/127.0.1.1\t${FQDN} ${HOSTNAME}/" /etc/hosts
    else
      echo -e "127.0.1.1\t${FQDN} ${HOSTNAME}" >> /etc/hosts
    fi
  fi

  md_track /etc/hostname
  md_track /etc/hosts
}

prompt_change_hostname() {
  local current choice new_name

  current="$(hostname -s | tr '[:upper:]' '[:lower:]')"

  if env_has_key HOSTNAME; then
    new_name="$(echo "${HOSTNAME:-}" | tr '[:upper:]' '[:lower:]')"
    [[ -n "$new_name" ]] || die "HOSTNAME is empty in environment"

    if ! valid_hostname "$new_name"; then
      die "Invalid HOSTNAME in environment. Use lowercase letters, digits and hyphen."
    fi

    if [[ "$new_name" == "$current" ]]; then
      HOSTNAME="$current"
      FQDN="${HOSTNAME}.${DOMAIN}"
      log "Using current hostname from environment: ${HOSTNAME}"
      return 0
    fi

    log "Using hostname from environment: ${new_name}"
    apply_hostname "$new_name"
    return 0
  fi

  tty_echo "${YELLOW}Change PC name?${NC}"
  tty_echo "1. No (${current})"
  tty_echo "2. Yes"

  while true; do
    read_tty choice "Select (1/2) [1]:"
    choice="${choice:-1}"

    case "$choice" in
      1)
        HOSTNAME="$current"
        FQDN="${HOSTNAME}.${DOMAIN}"
        return 0
        ;;
      2)
        while true; do
          read_tty new_name "Enter new PC name:"
          new_name="$(echo "$new_name" | tr '[:upper:]' '[:lower:]')"

          if valid_hostname "$new_name"; then
            apply_hostname "$new_name"
            return 0
          fi

          warn "Invalid hostname. Use lowercase letters, digits and hyphen."
        done
        ;;
      *)
        warn "Enter 1 or 2."
        ;;
    esac
  done
}

prompt_edition() {
  local choice

  if use_env_edition_if_available; then
    return 0
  fi

  tty_echo "${YELLOW}Select MultiDirectory edition:${NC}"
  tty_echo "1. Enterprise"
  tty_echo "2. Community"

  while true; do
    read_tty choice "Select (1/2) [1]:"
    choice="${choice:-1}"

    case "$choice" in
      1)
        EDITION="enterprise"
        WITH_SALT=1
        log "Selected edition: Enterprise"
        return 0
        ;;
      2)
        EDITION="community"
        WITH_SALT=0
        log "Selected edition: Community"
        return 0
        ;;
      *)
        warn "Enter 1 or 2."
        ;;
    esac
  done
}

load_or_prompt_edition() {
  if use_env_edition_if_available; then
    return 0
  fi

  if [[ -f "$INSTALL_ENV" ]]; then
    # shellcheck disable=SC1090
    . "$INSTALL_ENV"

    if [[ "${EDITION:-}" == "enterprise" && "${WITH_SALT:-}" == "1" ]]; then
      log "Using edition from install state: Enterprise"
      return 0
    fi

    if [[ "${EDITION:-}" == "community" && "${WITH_SALT:-}" == "0" ]]; then
      log "Using edition from install state: Community"
      return 0
    fi

    warn "Invalid edition state in ${INSTALL_ENV}, asking again"
  else
    warn "Install state file not found: ${INSTALL_ENV}, asking edition manually"
  fi

  prompt_edition
}

detect_default_iface() {
  ip route show default 2>/dev/null | awk '{print $5; exit}'
}

configure_dns_systemd_resolved() {
  local ns="$1"
  local resolved_dir="/etc/systemd/resolved.conf.d"
  local resolved_file="${resolved_dir}/MultiDirectory.conf"
  local resolv_target=""

  have_cmd systemctl || return 1
  systemctl list-unit-files systemd-resolved.service >/dev/null 2>&1 || return 1

  mkdir -p "$resolved_dir"
  md_backup_once "$resolved_file"

  cat > "$resolved_file" <<EOF
[Resolve]
DNS=${ns}
EOF

  chmod 0644 "$resolved_file"
  md_track "$resolved_file"

  systemctl enable systemd-resolved.service >/dev/null 2>&1 || true
  systemctl restart systemd-resolved.service || true

  if [[ -e /run/systemd/resolve/resolv.conf ]]; then
    resolv_target="/run/systemd/resolve/resolv.conf"
  elif [[ -e /run/systemd/resolve/stub-resolv.conf ]]; then
    resolv_target="/run/systemd/resolve/stub-resolv.conf"
  fi

  if [[ -n "$resolv_target" ]]; then
    md_backup_once /etc/resolv.conf
    rm -f /etc/resolv.conf
    ln -s "$resolv_target" /etc/resolv.conf
    md_track /etc/resolv.conf
    log "resolv.conf linked to ${resolv_target}"
  else
    warn "systemd-resolved resolv.conf target not found; /etc/resolv.conf symlink was not changed"
  fi

  log "Persistent DNS configured via systemd-resolved: ${ns}"
  return 0
}

configure_dns_networkmanager() {
  local ns="$1"
  local iface conn

  have_cmd nmcli || return 1
  systemctl is-active --quiet NetworkManager.service 2>/dev/null || return 1

  iface="$(detect_default_iface)"
  [[ -n "$iface" ]] || return 1

  conn="$(nmcli -t -f NAME,DEVICE connection show --active 2>/dev/null | awk -F: -v dev="$iface" '$2 == dev {print $1; exit}')"
  [[ -n "$conn" ]] || return 1

  nmcli connection modify "$conn"     ipv4.dns "$ns"     ipv4.ignore-auto-dns yes || return 1

  nmcli connection up "$conn" >/dev/null 2>&1 || true

  log "Persistent DNS configured via NetworkManager connection '${conn}': ${ns}"
  return 0
}

configure_dns_static_resolv_conf() {
  local ns="$1"
  local tmp
  local server

  md_backup_once /etc/resolv.conf

  if [[ -L /etc/resolv.conf ]]; then
    rm -f /etc/resolv.conf
  fi

  tmp="$(mktemp)"
  : > "$tmp"
  for server in $ns; do
    echo "nameserver ${server}" >> "$tmp"
  done

  if [[ -f /etc/resolv.conf ]]; then
    grep -vE '^nameserver[[:space:]]+' /etc/resolv.conf >> "$tmp" 2>/dev/null || true
  fi

  cp "$tmp" /etc/resolv.conf
  rm -f "$tmp"

  chmod 0644 /etc/resolv.conf
  md_track /etc/resolv.conf

  log "Persistent DNS configured via static /etc/resolv.conf: ${ns}"
}

md_set_resolv_first() {
  local ns="$1"

  if configure_dns_systemd_resolved "$ns"; then
    return 0
  fi

  if configure_dns_networkmanager "$ns"; then
    return 0
  fi

  configure_dns_static_resolv_conf "$ns"
}

normalize_dns_servers() {
  local raw="$1"
  local normalized="" item

  raw="${raw//,/ }"

  for item in $raw; do
    [[ -n "$item" ]] || continue
    if [[ "$item" =~ [[:space:]] ]]; then
      return 1
    fi
    normalized="${normalized}${normalized:+ }${item}"
  done

  [[ -n "$normalized" ]] || return 1
  printf '%s\n' "$normalized"
}

prompt_configure_dns() {
  local choice dns_input dns_servers

  if env_has_key MD_DNS_SERVER; then
    dns_input="${MD_DNS_SERVER:-}"

    case "$dns_input" in
      "" )
        warn "MD_DNS_SERVER is empty in environment; asking DNS interactively"
        ;;
      0|no|No|NO|none|None|NONE|skip|Skip|SKIP)
        log "DNS configuration skipped by environment"
        return 0
        ;;
      *)
        if ! dns_servers="$(normalize_dns_servers "$dns_input")"; then
          die "Invalid MD_DNS_SERVER in environment"
        fi

        log "Using DNS servers from environment: ${dns_servers}"
        MD_DNS_SERVER="$dns_servers"
        md_set_resolv_first "$dns_servers" || die "Failed to set DNS from environment"
        return 0
        ;;
    esac
  fi

  tty_echo "${YELLOW}Set MultiDirectory DNS servers?${NC}"
  tty_echo "1. Yes"
  tty_echo "2. No"

  while true; do
    read_tty choice "Select (1/2) [1]:"
    choice="${choice:-1}"
    case "$choice" in
      1)
        while true; do
          read_tty dns_input "Enter DNS server IPs, separated by comma:"
          if dns_servers="$(normalize_dns_servers "$dns_input")"; then
            MD_DNS_SERVER="$dns_servers"
            if md_set_resolv_first "$dns_servers"; then
              return 0
            else
              warn "Failed to set DNS. Please check the IP addresses and network."
            fi
          else
            warn "Invalid DNS server address list."
          fi
        done
        ;;
      2) log "DNS configuration skipped"; return 0 ;;
      *) warn "Enter 1 or 2." ;;
    esac
  done
}
