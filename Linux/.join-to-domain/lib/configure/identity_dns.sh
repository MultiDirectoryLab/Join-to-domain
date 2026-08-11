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

  tty_echo "${YELLOW}$(ui_text "Change PC name?" "Изменить имя компьютера?")${NC}"
  tty_echo "1. $(ui_text "No" "Нет") (${current})"
  tty_echo "2. $(ui_text "Yes" "Да")"

  while true; do
    read_tty choice "$(ui_text "Select (1/2) [1]:" "Выберите (1/2) [1]:")"
    choice="${choice:-1}"

    case "$choice" in
      1)
        HOSTNAME="$current"
        FQDN="${HOSTNAME}.${DOMAIN}"
        return 0
        ;;
      2)
        while true; do
          read_tty new_name "$(ui_text "Enter new PC name [${default_name}]:" "Введите новое имя компьютера [${default_name}]:")"
          new_name="${new_name:-$default_name}"
          new_name="$(echo "$new_name" | tr '[:upper:]' '[:lower:]')"

          if valid_hostname "$new_name"; then
            apply_hostname "$new_name"
            return 0
          fi

          warn "$(ui_text "Invalid hostname. Use lowercase letters, digits and hyphen." "Некорректное имя. Используйте строчные латинские буквы, цифры и дефис.")"
        done
        ;;
      *)
        warn "$(ui_text "Enter 1 or 2." "Введите 1 или 2.")"
        ;;
    esac
  done
}

select_rejoin_hostname() {
  local current preferred candidate

  current="$(hostname -s | tr '[:upper:]' '[:lower:]')"
  EXISTING_COMPUTER_FOUND=0

  preferred="${SAVED_HOSTNAME:-$current}"
  preferred="$(printf '%s' "$preferred" | tr '[:upper:]' '[:lower:]')"
  if ! valid_hostname "$preferred"; then
    if valid_hostname "$current"; then
      preferred="$current"
    else
      die "$(ui_text "Rejoin cannot determine a valid computer name from join state or the current hostname" "Не удалось определить допустимое имя компьютера для Rejoin из состояния Join или текущего hostname")"
    fi
  fi

  HOSTNAME="$preferred"
  FQDN="${HOSTNAME}.${DOMAIN}"
  info "$(ui_text "Using computer name: ${HOSTNAME}" "Используется имя компьютера: ${HOSTNAME}")"
  info "$(ui_text "Rejoin: searching LDAP for computer ${HOSTNAME}" "Повторное присоединение: поиск компьютера ${HOSTNAME} в LDAP")"

  if [[ -n "${SAVED_COMPUTER_DN:-}" ]] && lookup_computer_by_dn "$SAVED_COMPUTER_DN"; then
    use_computer_lookup_result
  elif lookup_computer_by_name "$preferred"; then
    use_computer_lookup_result
  elif [[ "$preferred" != "$current" ]] && valid_hostname "$current" \
      && lookup_computer_by_name "$current"; then
    use_computer_lookup_result
  fi

  if [[ "${EXISTING_COMPUTER_FOUND:-0}" == "1" ]]; then
    candidate="${COMPUTER_LOOKUP_CN:-$preferred}"
    candidate="$(printf '%s' "$candidate" | tr '[:upper:]' '[:lower:]')"
    valid_hostname "$candidate" \
      || die "$(ui_text "The existing LDAP computer has an invalid cn: ${candidate}" "У существующего объекта компьютера в LDAP некорректный cn: ${candidate}")"
    if [[ "$candidate" != "$current" ]]; then
      apply_hostname "$candidate"
    else
      HOSTNAME="$current"
      FQDN="${HOSTNAME}.${DOMAIN}"
    fi
    info "$(ui_text "Existing computer found; hostname prompt skipped: ${HOSTNAME}" "Существующий компьютер найден; запрос имени пропущен: ${HOSTNAME}")"
    log "Rejoin will reuse exact computer DN: ${COMPUTER_DN}"
    return 0
  fi

  if [[ "$preferred" != "$current" ]]; then
    apply_hostname "$preferred"
  fi
  info "$(ui_text "No existing computer object was found; the known hostname will be used: ${HOSTNAME}" "Существующий объект компьютера не найден; будет использовано известное имя: ${HOSTNAME}")"
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

  tty_echo "${YELLOW}$(ui_text "Select MultiDirectory edition:" "Выберите редакцию MultiDirectory:")${NC}"
  tty_echo "1. Enterprise"
  tty_echo "2. Community"

  while true; do
    read_tty choice "$(ui_text "Select (1/2) [${default_choice} - ${default_label}]:" "Выберите (1/2) [${default_choice} - ${default_label}]:")"
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
        warn "$(ui_text "Enter 1 or 2." "Введите 1 или 2.")"
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
  systemctl is-active --quiet systemd-resolved.service 2>/dev/null || return 1

  # An installed/running resolved is not necessarily the system resolver.  Only
  # use it when resolv.conf is actually connected to one of its managed files.
  [[ -L /etc/resolv.conf ]] || return 1
  resolv_target="$(readlink -f /etc/resolv.conf 2>/dev/null || true)"
  case "$resolv_target" in
    /run/systemd/resolve/resolv.conf|/run/systemd/resolve/stub-resolv.conf) ;;
    *) return 1 ;;
  esac

  mkdir -p "$resolved_dir"
  md_backup_once "$resolved_file"

  cat > "$resolved_file" <<EOF
[Resolve]
DNS=${ns}
EOF

  chmod 0644 "$resolved_file"
  md_track "$resolved_file"

  systemctl restart systemd-resolved.service || return 1
  log "Resolver backend: systemd-resolved (${resolv_target})"

  log "Persistent DNS configured via systemd-resolved: ${ns}"
  return 0
}

configure_dns_networkmanager() {
  local ns="$1"
  local nm_dns="$1"
  local iface conn_uuid previous_dns previous_ignore_auto_dns
  local previous_dns_priority previous_ipv6_ignore_auto_dns
  local applied_dns applied_ignore_auto_dns attempt

  have_cmd nmcli || return 1
  LC_ALL=C nmcli -t -f RUNNING general 2>/dev/null | grep -qx 'running' || return 1

  iface="$(detect_default_iface)"
  [[ -n "$iface" ]] || return 1

  conn_uuid="$(
    LC_ALL=C nmcli -t -f UUID,DEVICE connection show --active 2>/dev/null \
      | awk -F: -v dev="$iface" '$2 == dev {print $1; exit}'
  )"
  [[ -n "$conn_uuid" ]] || return 1

  if [[ ! -f "$MD_NM_DNS_STATE" ]]; then
    previous_dns="$(LC_ALL=C nmcli -g ipv4.dns connection show uuid "$conn_uuid" 2>/dev/null | paste -sd, -)"
    previous_ignore_auto_dns="$(LC_ALL=C nmcli -g ipv4.ignore-auto-dns connection show uuid "$conn_uuid" 2>/dev/null | head -n1)"
    previous_dns_priority="$(LC_ALL=C nmcli -g ipv4.dns-priority connection show uuid "$conn_uuid" 2>/dev/null | head -n1)"
    previous_ipv6_ignore_auto_dns="$(LC_ALL=C nmcli -g ipv6.ignore-auto-dns connection show uuid "$conn_uuid" 2>/dev/null | head -n1)"

    {
      write_join_state_var CONNECTION_UUID "$conn_uuid"
      write_join_state_var IPV4_DNS "$previous_dns"
      write_join_state_var IPV4_IGNORE_AUTO_DNS "${previous_ignore_auto_dns:-no}"
      write_join_state_var IPV4_DNS_PRIORITY "${previous_dns_priority:-0}"
      write_join_state_var IPV6_IGNORE_AUTO_DNS "${previous_ipv6_ignore_auto_dns:-no}"
    } > "$MD_NM_DNS_STATE"
    chmod 600 "$MD_NM_DNS_STATE"
    log "Saved NetworkManager DNS state for connection ${conn_uuid}"
  fi

  LC_ALL=C nmcli connection modify uuid "$conn_uuid" \
    ipv4.dns "$nm_dns" \
    ipv4.ignore-auto-dns yes \
    ipv4.dns-priority -50 \
    ipv6.ignore-auto-dns yes \
    || return 1

  if ! LC_ALL=C nmcli device reapply "$iface" >/dev/null 2>&1; then
    LC_ALL=C nmcli connection up uuid "$conn_uuid" >/dev/null 2>&1 || return 1
  fi

  applied_ignore_auto_dns="$(LC_ALL=C nmcli -g ipv4.ignore-auto-dns connection show uuid "$conn_uuid" 2>/dev/null | head -n1)"
  [[ "$applied_ignore_auto_dns" == "yes" ]] || {
    warn "NetworkManager did not apply ipv4.ignore-auto-dns=yes for connection ${conn_uuid}"
    return 1
  }

  for attempt in 1 2 3 4 5; do
    applied_dns="$(LC_ALL=C nmcli -g IP4.DNS device show "$iface" 2>/dev/null | paste -sd' ' -)"
    log "NetworkManager DNS readiness ${attempt}/5 on ${iface}: ${applied_dns:-not reported}"
    dns_server_lists_match "$ns" "$applied_dns" && break
    (( attempt < 5 )) && sleep 1
  done
  dns_server_lists_match "$ns" "$applied_dns" || {
    warn "NetworkManager effective DNS does not contain all requested servers on ${iface}"
    log_dns_diagnostics "$ns" "$iface" "$conn_uuid"
    return 1
  }

  if have_cmd resolvectl; then
    resolvectl flush-caches >/dev/null 2>&1 || true
  elif have_cmd systemd-resolve; then
    systemd-resolve --flush-caches >/dev/null 2>&1 || true
  fi

  log "NetworkManager DNS value: ${nm_dns}"
  log "Persistent DNS configured via NetworkManager connection UUID ${conn_uuid}: ${ns}"
  return 0
}

restore_networkmanager_dns_state() {
  local CONNECTION_UUID=""
  local IPV4_DNS=""
  local IPV4_IGNORE_AUTO_DNS="no"
  local IPV4_DNS_PRIORITY="0"
  local IPV6_IGNORE_AUTO_DNS="no"

  [[ -f "$MD_NM_DNS_STATE" ]] || return 0
  have_cmd nmcli || {
    warn "Cannot restore NetworkManager DNS state: nmcli is unavailable"
    return 1
  }

  # The file is generated by write_join_state_var in a root-only state directory.
  # shellcheck disable=SC1090
  . "$MD_NM_DNS_STATE"

  [[ -n "$CONNECTION_UUID" ]] || {
    warn "Cannot restore NetworkManager DNS state: connection UUID is missing"
    return 1
  }

  LC_ALL=C nmcli connection modify uuid "$CONNECTION_UUID" \
    ipv4.dns "$IPV4_DNS" \
    ipv4.ignore-auto-dns "$IPV4_IGNORE_AUTO_DNS" \
    ipv4.dns-priority "$IPV4_DNS_PRIORITY" \
    ipv6.ignore-auto-dns "$IPV6_IGNORE_AUTO_DNS" \
    || {
      warn "Failed to restore NetworkManager DNS state for ${CONNECTION_UUID}"
      return 1
    }

  LC_ALL=C nmcli connection up uuid "$CONNECTION_UUID" >/dev/null 2>&1 || {
    warn "Failed to activate restored NetworkManager DNS state for ${CONNECTION_UUID}"
    return 1
  }
  rm -f "$MD_NM_DNS_STATE"
  log "Restored NetworkManager DNS state for connection ${CONNECTION_UUID}"
  info "$(ui_text "Original NetworkManager DNS settings were restored" "Исходные настройки DNS NetworkManager восстановлены")"
}

configure_dns_static_resolv_conf() {
  local ns="$1"
  local tmp_file

  if [[ -L /etc/resolv.conf ]]; then
    warn "/etc/resolv.conf is a symlink; direct update skipped to avoid breaking managed resolver configuration"
    return 1
  fi

  md_backup_once /etc/resolv.conf

  touch /etc/resolv.conf
  tmp_file="$(mktemp /etc/resolv.conf.multidirectory.XXXXXX)"

  if ! awk -v md_servers="$ns" '
    BEGIN {
      count = split(md_servers, servers, /[[:space:]]+/)
      for (i = 1; i <= count; i++) {
        if (servers[i] != "") {
          md[servers[i]] = 1
          print "nameserver " servers[i]
        }
      }
    }
    /^[[:space:]]*nameserver[[:space:]]+/ {
      if ($2 in md) next
    }
    { print }
  ' /etc/resolv.conf >"$tmp_file"; then
    rm -f "$tmp_file"
    return 1
  fi

  chmod 0644 "$tmp_file"
  if ! mv -f "$tmp_file" /etc/resolv.conf; then
    rm -f "$tmp_file"
    return 1
  fi

  md_track /etc/resolv.conf

  log "MultiDirectory DNS placed first in static /etc/resolv.conf: ${ns}"
}

md_set_resolv_first() {
  local ns="$1"

  # NetworkManager owns the active connection on the common Astra setup, even
  # when it delegates lookups to systemd-resolved.  Configure that owner first.
  if configure_dns_networkmanager "$ns"; then
    return 0
  fi

  if configure_dns_systemd_resolved "$ns"; then
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

MAX_DNS_SERVERS=3

normalize_dns_servers() {
  local raw="$1"
  local cleaned
  local -a parts
  local item normalized=""

  cleaned="$(sanitize_input "$raw")"
  validate_utf8_input "$cleaned" || return 1

  [[ -n "$cleaned" ]] || return 1
  [[ "$cleaned" != *, ]] || return 1
  [[ "$cleaned" != ,* ]] || return 1

  # Accept the interactive CSV form and the legacy space-separated state form.
  cleaned="${cleaned//,/ }"
  read -r -a parts <<< "$cleaned"
  [[ "${#parts[@]}" -ge 1 && "${#parts[@]}" -le "$MAX_DNS_SERVERS" ]] || return 1

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

dns_server_lists_match() {
  local requested="$1" effective="$2" server

  for server in $requested; do
    [[ " $effective " == *" $server "* ]] || return 1
  done
}

log_dns_diagnostics() {
  local requested="${1:-${MD_DNS_SERVER:-}}"
  local iface="${2:-$(detect_default_iface)}"
  local conn_uuid="${3:-}"

  log "Requested DNS servers: ${requested:-not configured}"
  log "Active NetworkManager interface: ${iface:-not detected}"
  [[ -n "$conn_uuid" ]] && log "Active NetworkManager connection UUID: ${conn_uuid}"
  if have_cmd nmcli && [[ -n "$iface" ]]; then
    log "NetworkManager effective DNS: $(LC_ALL=C nmcli -g IP4.DNS device show "$iface" 2>/dev/null | paste -sd' ' -)"
  fi
  if have_cmd resolvectl; then
    log "resolvectl DNS: $(resolvectl dns "$iface" 2>/dev/null | tr '\n' ' ')"
  fi
  log "/etc/resolv.conf target: $(readlink -f /etc/resolv.conf 2>/dev/null || printf '%s' /etc/resolv.conf)"
  while IFS= read -r line; do log "/etc/resolv.conf: ${line}"; done < /etc/resolv.conf
}

log_direct_dns_queries() {
  local fqdn="$1" server result

  for server in ${MD_DNS_SERVER:-}; do
    if have_cmd dig; then
      result="$(dig +time=2 +tries=1 +short @"$server" "$fqdn" A 2>/dev/null | paste -sd, -)"
      log "Direct DNS query ${server} for ${fqdn}: ${result:-no answer}"
    elif have_cmd nslookup; then
      result="$(nslookup "$fqdn" "$server" 2>/dev/null | awk '/^Address: / {print $2}' | paste -sd, -)"
      log "Direct DNS query ${server} for ${fqdn}: ${result:-no answer}"
    fi
  done
}

show_dns_failure_summary() {
  local iface configured

  iface="$(detect_default_iface)"
  configured="not configured"
  [[ -n "${MD_DNS_SERVER:-}" ]] && configured="$(dns_servers_csv "$MD_DNS_SERVER")"
  info "$(ui_text "Configured DNS servers: ${configured}" "Настроенные DNS-серверы: ${configured}")"
  info "$(ui_text "Active NetworkManager interface: ${iface:-not detected}" "Активный интерфейс NetworkManager: ${iface:-не определён}")"
  info "$(ui_text "See the detailed resolver diagnostics in the log." "Подробная диагностика резолвера записана в журнал.")"
}

wait_for_dns_resolution() {
  local fqdn="$1" attempt address

  for attempt in 1 2 3 4 5; do
    address="$(getent ahostsv4 "$fqdn" 2>/dev/null | awk 'NR == 1 {print $1}')"
    if [[ -n "$address" ]]; then
      log "DNS resolution succeeded on attempt ${attempt}/5: ${fqdn} -> ${address}"
      return 0
    fi
    log "DNS resolution pending ${attempt}/5: ${fqdn}"
    (( attempt < 5 )) && sleep 1
  done

  log_dns_diagnostics
  log_direct_dns_queries "$fqdn"
  return 1
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
          die "Invalid MD_DNS_SERVER in environment. Example: 8.8.8.8,1.1.1.1 or 192.168.69.51,8.8.8.8,1.1.1.1"
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

  tty_echo "${YELLOW}$(ui_text "Set MultiDirectory DNS servers?" "Настроить DNS-серверы MultiDirectory?")${NC}"
  if [[ -n "$default_dns_csv" ]]; then
    tty_echo "1. $(ui_text "Yes" "Да") (${default_dns_csv})"
  else
    tty_echo "1. $(ui_text "Yes" "Да")"
  fi
  tty_echo "2. $(ui_text "No" "Нет")"

  while true; do
    read_tty choice "$(ui_text "Select (1/2) [${default_choice}]:" "Выберите (1/2) [${default_choice}]:")"
    choice="${choice:-$default_choice}"
    case "$choice" in
      1)
        while true; do
          dns_input=""
          dns_servers=""
          if [[ -n "$default_dns_csv" ]]; then
            read_tty dns_input "$(ui_text "Enter DNS server IPs, separated by comma [${default_dns_csv}]:" "Введите IP-адреса DNS-серверов через запятую [${default_dns_csv}]:")"
            dns_input="${dns_input:-$default_dns_csv}"
          else
            read_tty dns_input "$(ui_text "Enter DNS server IPs, separated by comma [example: 8.8.8.8 or 192.168.69.51,8.8.8.8,1.1.1.1]:" "Введите IP-адреса DNS-серверов через запятую [пример: 8.8.8.8 или 192.168.69.51,8.8.8.8,1.1.1.1]:")"
          fi
          if dns_servers="$(normalize_dns_servers "$dns_input")"; then
            log "DNS input validated: $(dns_servers_csv "$dns_servers")"
            MD_DNS_SERVER="$dns_servers"
            if md_set_resolv_first "$dns_servers"; then
              return 0
            else
              warn "$(ui_text "Failed to set DNS. Please check the IP addresses and network." "Не удалось настроить DNS. Проверьте IP-адреса и сеть.")"
            fi
          else
            warn "$(ui_text "Invalid DNS input. Example: 8.8.8.8,1.1.1.1 or 192.168.69.51,8.8.8.8,1.1.1.1" "Некорректные DNS-адреса. Пример: 8.8.8.8,1.1.1.1 или 192.168.69.51,8.8.8.8,1.1.1.1")"
          fi
        done
        ;;
      2) log "DNS configuration skipped"; return 0 ;;
      *) warn "$(ui_text "Enter 1 or 2." "Введите 1 или 2.")" ;;
    esac
  done
}
