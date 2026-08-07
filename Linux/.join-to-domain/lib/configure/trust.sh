install_md_server_certificate() {
  local tmp_cert
  local tmp_trusted
  local fingerprint
  local trust_file

  need_cmd openssl
  tmp_cert="$(mktemp)"
  tmp_trusted="$(mktemp)"
  trap 'rm -f "${tmp_cert:-}" "${tmp_trusted:-}"; trap - RETURN' RETURN

  log "Retrieving TLS certificate from ${API_HOST}:443"
  if ! openssl s_client \
      -connect "${API_HOST}:443" \
      -servername "${API_HOST}" \
      -showcerts </dev/null 2>/dev/null \
      | openssl x509 -outform PEM >"${tmp_cert}"; then
    die "Failed to retrieve TLS certificate from ${API_HOST}:443"
  fi

  if valid_ipv4_address "${API_HOST}"; then
    openssl x509 -in "${tmp_cert}" -noout -checkip "${API_HOST}" >/dev/null 2>&1 \
      || die "Server certificate does not cover IP address ${API_HOST}"
  else
    openssl x509 -in "${tmp_cert}" -noout -checkhost "${API_HOST}" >/dev/null 2>&1 \
      || die "Server certificate does not cover DNS name ${API_HOST}"
  fi

  fingerprint="$(openssl x509 -in "${tmp_cert}" -noout -fingerprint -sha256 | sed 's/^.*=//')"
  warn "$(ui_text "Trusting certificate received on first connection (TOFU), SHA-256: ${fingerprint}" "Устанавливается доверие сертификату, полученному при первом подключении (TOFU), SHA-256: ${fingerprint}")"

  if [[ -d /usr/local/share/ca-certificates ]] && have_cmd update-ca-certificates; then
    trust_file="/usr/local/share/ca-certificates/multidirectory-${API_HOST}.crt"
    md_backup_once "${trust_file}"
    install -m 0644 "${tmp_cert}" "${trust_file}"
    md_track "${trust_file}"
    update-ca-certificates >/dev/null
  elif have_cmd update-ca-trust; then
    trust_file="/etc/pki/ca-trust/source/anchors/multidirectory-${API_HOST}.crt"

    # RHEL's shared trust store may ignore a legacy self-signed server
    # certificate that has no Basic Constraints extension.  Store it as an
    # OpenSSL TRUSTED CERTIFICATE with an explicit TLS server trust purpose so
    # update-ca-trust includes it in the generated CA bundle.
    install -d -m 0755 "$(dirname -- "${trust_file}")"
    md_backup_once "${trust_file}"
    openssl x509 \
      -in "${tmp_cert}" \
      -addtrust serverAuth \
      -trustout \
      -out "${tmp_trusted}" \
      || die "Failed to mark the MultiDirectory certificate as trusted for TLS"
    install -m 0644 "${tmp_trusted}" "${trust_file}"
    md_track "${trust_file}"
    update-ca-trust extract >/dev/null
  else
    die "Unsupported system CA trust store"
  fi

  # Some RHEL-like distributions generate their system trust bundle in a
  # location different from the CA file used by curl.  Keep every API request
  # in this join process pinned to the certificate that was just verified and
  # installed instead of relying on curl's compile-time CA bundle path.
  CURL_CA_BUNDLE="${trust_file}"
  export CURL_CA_BUNDLE

  curl -sS --connect-timeout "${API_CONNECT_TIMEOUT}" --max-time "${API_MAX_TIME}" \
    "https://${API_HOST}/" -o /dev/null \
    || die "TLS verification failed after installing the MultiDirectory certificate"

  log "MultiDirectory TLS certificate installed: ${trust_file}"
}

renew_md_server_certificate() {
  need_root
  setup_logging
  load_os_release
  md_init_state
  load_join_state
  API_HOST="${SAVED_API_HOST:-}"

  while [[ -z "${API_HOST}" ]]; do
    read_tty API_HOST "$(ui_text "Enter MULTIDIRECTORY server address (IPv4 or FQDN):" "Введите адрес сервера MULTIDIRECTORY (IPv4 или FQDN):")"
    API_HOST="$(sanitize_input "${API_HOST}")"

    if [[ -z "${API_HOST}" ]]; then
      warn "$(ui_text "Server address cannot be empty" "Адрес сервера не может быть пустым")"
      continue
    fi

    if ! valid_api_host "${API_HOST}"; then
      warn "$(ui_text "Invalid server address: ${API_HOST}" "Некорректный адрес сервера: ${API_HOST}")"
      API_HOST=""
    fi
  done

  log "Checking API host address: ${API_HOST}"
  api_host_resolution_ok "${API_HOST}" || die "DNS resolution failed: ${API_HOST}"

  install_md_server_certificate
  log "MultiDirectory TLS certificate renewed successfully"
  ok "$(ui_text "MultiDirectory TLS certificate renewed successfully" "TLS-сертификат MultiDirectory успешно обновлён")"
}
