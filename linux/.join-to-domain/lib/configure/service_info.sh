# Service discovery uses the same pinned endpoint and accepted TLS certificate
# as all subsequent API calls. The payload is data, never shell input.
probe_service_dns() {
  local server="$1" domain="$2" reply latency
  reply="$(LC_ALL=C dig "@${server}" "${domain}." SOA +time=2 +tries=1 +noall +comments +answer +stats 2>/dev/null)" || return 1
  grep -q 'status: NOERROR' <<< "$reply" || return 1
  awk '$4 == "SOA" { found=1 } END { exit !found }' <<< "$reply" || return 1
  latency="$(awk '/^;; Query time:/ { print $4; exit }' <<< "$reply")"
  [[ "$latency" =~ ^[0-9]+$ ]] || return 1
  printf '%s %s\n' "$latency" "$server"
}

select_service_dns() {
  local domain="$1" server index=0 pid results selected
  local -a pids=()
  shift
  results="$(mktemp -d "${TMPDIR:-/tmp}/md-dns-probes.XXXXXX")" || return 1
  # Batches bound both concurrent processes and DNS timeout costs for GEO.
  for server in "$@"; do
    (probe_service_dns "$server" "$domain" > "$results/$index") &
    pids+=("$!")
    index=$((index + 1))
    if (( ${#pids[@]} == 8 )); then
      for pid in "${pids[@]}"; do wait "$pid" || true; done
      pids=()
    fi
  done
  for pid in "${pids[@]}"; do wait "$pid" || true; done
  selected="$(cat "$results/"* | LC_ALL=C sort -n -k1,1 -k2,2 | awk 'NR <= 3 { printf "%s%s", sep, $2; sep=" " } END { print "" }')"
  rm -rf -- "$results"
  [[ -n "$selected" ]] || return 1
  printf '%s\n' "$selected"
}

load_service_info() {
  local body http_code domain edition server selected
  local -a servers=()
  body="$(mktemp "${TMPDIR:-/tmp}/md-service-info.XXXXXX")" || return 1
  chmod 600 "$body"
  if ! http_code="$(curl -sS "${API_CURL_RESOLVE[@]}" \
      --connect-timeout "${API_CONNECT_TIMEOUT}" --max-time "${API_MAX_TIME}" \
      -H 'accept: application/json' "https://${API_HOST}/api/system/service_info" \
      -o "$body" -w '%{http_code}')" || [[ "$http_code" != 200 ]]; then
    rm -f "$body"
    warn "Could not retrieve MultiDirectory service_info (HTTP ${http_code:-000})"
    return 1
  fi
  if ! jq -se 'length == 1 and (.[0] | type == "object" and
      (.domain_ldap_name | type == "string") and
      (.md_edition == "Enterprise" or .md_edition == "Community") and
      (.md_dns_servers | type == "array" and length > 0 and all(.[]; type == "string")))' "$body" >/dev/null 2>&1; then
    rm -f "$body"
    warn 'Invalid MultiDirectory service_info response'
    return 1
  fi
  domain="$(jq -r '.domain_ldap_name | ascii_downcase' "$body")"
  edition="$(jq -r '.md_edition | ascii_downcase' "$body")"
  if (( ${#domain} > 253 )) || ! valid_join_domain "$domain" || valid_ipv4_address "$domain"; then
    rm -f "$body"
    warn 'Invalid domain_ldap_name in service_info'
    return 1
  fi
  mapfile -t servers < <(jq -r '.md_dns_servers | unique[]' "$body")
  rm -f "$body"
  for server in "${servers[@]}"; do
    if ! valid_ipv4_address "$server"; then
      warn 'Invalid DNS server in service_info; IPv4 addresses are required'
      return 1
    fi
  done
  if ! selected="$(select_service_dns "$domain" "${servers[@]}")"; then
    warn 'No DNS server from service_info answers domain SOA queries'
    return 1
  fi
  DOMAIN="$domain"
  EDITION="$edition"
  WITH_SALT=0
  [[ "$edition" != enterprise ]] || WITH_SALT=1
  MD_DNS_SERVER="$selected"
  JOIN_TO_DOMAIN_ENV_KEYS="${JOIN_TO_DOMAIN_ENV_KEYS:-} EDITION WITH_SALT MD_DNS_SERVER "
  log "MultiDirectory service_info: domain=${DOMAIN}; edition=${EDITION}; fastest DNS=${MD_DNS_SERVER}"
}

select_service_api_host() {
  local candidate="${API_HOST:-${SAVED_API_HOST:-}}" choice
  # Manual resolver recovery must not reuse an API-provided DNS override.
  local JOIN_TO_DOMAIN_ENV_KEYS="${JOIN_TO_DOMAIN_ENV_KEYS:-}"
  JOIN_TO_DOMAIN_ENV_KEYS="${JOIN_TO_DOMAIN_ENV_KEYS//MD_DNS_SERVER/}"
  while true; do
    if [[ -z "$candidate" ]]; then
      read_tty candidate "$(ui_text "Enter MultiDirectory IPv4 address or FQDN [${SAVED_API_HOST:-}]:" "Введите IPv4-адрес или FQDN MultiDirectory [${SAVED_API_HOST:-}]:")" || return 1
      candidate="${candidate:-${SAVED_API_HOST:-}}"
    fi
    if ! valid_api_host "$candidate"; then
      warn "$(ui_text 'Invalid server address' 'Некорректный адрес сервера')"
      candidate=""
      continue
    fi
    if pin_api_host "$candidate"; then
      API_HOST="$candidate"
      break
    fi
    warn "$(ui_text "Cannot resolve ${candidate}" "Не удалось разрешить ${candidate}")"
    tty_echo "1. $(ui_text 'Enter another address or server IP' 'Ввести другой адрес или IP сервера')"
    tty_echo "2. $(ui_text 'Configure DNS servers' 'Настроить DNS-серверы')"
    tty_echo "3. $(ui_text 'Cancel' 'Отмена')"
    read_tty choice "$(ui_text 'Select (1/2/3) [1]:' 'Выберите (1/2/3) [1]:')" || return 1
    case "${choice:-1}" in
      1)
        read_tty candidate "$(ui_text 'MultiDirectory server IPv4 address or FQDN:' 'IPv4-адрес или FQDN сервера MultiDirectory:')" || return 1
        ;;
      2) prompt_configure_dns || return 1 ;;
      3) return 1 ;;
      *) warn "$(ui_text 'Enter 1, 2 or 3' 'Введите 1, 2 или 3')" ;;
    esac
  done
}

prepare_service_info() {
  select_service_api_host || return 1
  install_md_server_certificate || return 1
  load_service_info
}
