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
  local current default_name choice new_name

  current="$(hostname -s | tr '[:upper:]' '[:lower:]')"
  default_name="$current"
  if [[ -n "${SAVED_HOSTNAME:-}" ]]; then
    default_name="$SAVED_HOSTNAME"
  fi

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
  tty_echo "1. No (${default_name})"
  tty_echo "2. Yes"

  while true; do
    read_tty choice "Select (1/2) [1]:"
    choice="${choice:-1}"

    case "$choice" in
      1)
        if [[ "$default_name" == "$current" ]]; then
          HOSTNAME="$current"
          FQDN="${HOSTNAME}.${DOMAIN}"
        else
          apply_hostname "$default_name"
        fi
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
  local choice default_choice default_label

  if use_env_edition_if_available; then
    return 0
  fi

  default_choice=1
  default_label="Enterprise"
  if [[ "${SAVED_EDITION:-}" == "community" ]]; then
    default_choice=2
    default_label="Community"
  fi

  tty_echo "${YELLOW}Select MultiDirectory edition:${NC}"
  tty_echo "1. Enterprise"
  tty_echo "2. Community"

  while true; do
    read_tty choice "Select (1/2) [${default_choice} - ${default_label}]:"
    choice="${choice:-$default_choice}"

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

  if [[ -n "${SAVED_EDITION:-}" ]]; then
    prompt_edition
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
    if [[ -L /etc/resolv.conf ]]; then
      log "resolv.conf is a symlink; direct replacement skipped"
    else
      warn "/etc/resolv.conf is not a symlink; systemd-resolved was configured without replacing the file"
    fi
  else
    warn "systemd-resolved resolv.conf target not found; /etc/resolv.conf symlink was not changed"
  fi

  log "Persistent DNS configured via systemd-resolved: ${ns}"
  return 0
}

configure_dns_networkmanager() {
  local ns="$1"
  local nm_dns="$1"
  local iface conn

  have_cmd nmcli || return 1
  systemctl is-active --quiet NetworkManager.service 2>/dev/null || return 1

  iface="$(detect_default_iface)"
  [[ -n "$iface" ]] || return 1

  conn="$(nmcli -t -f NAME,DEVICE connection show --active 2>/dev/null | awk -F: -v dev="$iface" '$2 == dev {print $1; exit}')"
  [[ -n "$conn" ]] || return 1

  nmcli connection modify "$conn" ipv4.dns "$nm_dns" ipv4.ignore-auto-dns yes || return 1

  nmcli connection up "$conn" >/dev/null 2>&1 || true

  log "NetworkManager DNS value: ${nm_dns}"
  log "Persistent DNS configured via NetworkManager connection '${conn}': ${ns}"
  return 0
}

configure_dns_static_resolv_conf() {
  local ns="$1"
  local server

  if [[ -L /etc/resolv.conf ]]; then
    warn "/etc/resolv.conf is a symlink; direct append skipped to avoid breaking managed resolver configuration"
    return 1
  fi

  md_backup_once /etc/resolv.conf

  touch /etc/resolv.conf
  for server in $ns; do
    if grep -Eq "^[[:space:]]*nameserver[[:space:]]+${server}([[:space:]]|$)" /etc/resolv.conf 2>/dev/null; then
      log "nameserver already present in resolv.conf: ${server}"
      continue
    fi

    printf 'nameserver %s\n' "$server" >> /etc/resolv.conf
    log "Added nameserver to resolv.conf: ${server}"
  done

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

valid_ipv4_address() {
  local ip="$1"
  local IFS=.
  local octets octet

  [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
  read -r -a octets <<< "$ip"
  [[ "${#octets[@]}" -eq 4 ]] || return 1

  for octet in "${octets[@]}"; do
    [[ "$octet" =~ ^[0-9]+$ ]] || return 1
    (( 10#$octet >= 0 && 10#$octet <= 255 )) || return 1
  done

  return 0
}

normalize_dns_servers() {
  local raw="$1"
  local cleaned
  local -a parts
  local item normalized=""

  cleaned="$(sanitize_input "$raw")"
  validate_utf8_input "$cleaned" || return 1

  [[ -n "$cleaned" ]] || return 1
  [[ "$cleaned" != *,*,* ]] || return 1
  [[ "$cleaned" != *, ]] || return 1
  [[ "$cleaned" != ,* ]] || return 1

  IFS=',' read -r -a parts <<< "$cleaned"
  [[ "${#parts[@]}" -ge 1 && "${#parts[@]}" -le 2 ]] || return 1

  for item in "${parts[@]}"; do
    item="$(sanitize_input "$item")"
    [[ -n "$item" ]] || return 1
    valid_ipv4_address "$item" || return 1
    normalized="${normalized}${normalized:+ }${item}"
  done

  [[ -n "$normalized" ]] || return 1
  printf '%s\n' "$normalized"
}

dns_servers_csv() {
  local ns="$1"

  printf '%s\n' "${ns// /,}"
}

prompt_configure_dns() {
  local choice dns_input dns_servers default_dns default_choice
  local default_dns_csv

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
          die "Invalid MD_DNS_SERVER in environment. Example: 8.8.8.8,1.1.1.1"
        fi

        log "DNS input validated: $(dns_servers_csv "$dns_servers")"
        log "Using DNS servers from environment: ${dns_servers}"
        MD_DNS_SERVER="$dns_servers"
        md_set_resolv_first "$dns_servers" || die "Failed to set DNS from environment"
        return 0
        ;;
    esac
  fi

  default_dns="${SAVED_DNS_SERVERS:-}"
  default_dns_csv=""
  default_choice=1
  if [[ -n "$default_dns" ]]; then
    default_dns_csv="$(dns_servers_csv "$default_dns")"
  fi

  tty_echo "${YELLOW}Set MultiDirectory DNS servers?${NC}"
  if [[ -n "$default_dns_csv" ]]; then
    tty_echo "1. Yes (${default_dns_csv})"
  else
    tty_echo "1. Yes"
  fi
  tty_echo "2. No"

  while true; do
    read_tty choice "Select (1/2) [${default_choice}]:"
    choice="${choice:-$default_choice}"
    case "$choice" in
      1)
        while true; do
          dns_input=""
          dns_servers=""
          if [[ -n "$default_dns_csv" ]]; then
            read_tty dns_input "Enter DNS server IPs, separated by comma [${default_dns_csv}]:"
            dns_input="${dns_input:-$default_dns_csv}"
          else
            read_tty dns_input "Enter DNS server IPs, separated by comma [example: 8.8.8.8 or 8.8.8.8,1.1.1.1]:"
          fi
          if dns_servers="$(normalize_dns_servers "$dns_input")"; then
            log "DNS input validated: $(dns_servers_csv "$dns_servers")"
            MD_DNS_SERVER="$dns_servers"
            if md_set_resolv_first "$dns_servers"; then
              return 0
            else
              warn "Failed to set DNS. Please check the IP addresses and network."
            fi
          else
            warn "Invalid DNS input. Example: 8.8.8.8,1.1.1.1"
          fi
        done
        ;;
      2) log "DNS configuration skipped"; return 0 ;;
      *) warn "Enter 1 or 2." ;;
    esac
  done
}
