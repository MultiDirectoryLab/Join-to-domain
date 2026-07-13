install_md_server_certificate() (
  local tmp_cert
  local fingerprint
  local trust_file

  need_cmd openssl
  tmp_cert="$(mktemp)"
  trap 'rm -f "${tmp_cert:-}"' EXIT

  log "Retrieving TLS certificate from ${API_HOST}:443"
  if ! openssl s_client \
      -connect "${API_HOST}:443" \
      -servername "${API_HOST}" \
      -showcerts </dev/null 2>/dev/null \
      | openssl x509 -outform PEM >"${tmp_cert}"; then
    die "Failed to retrieve TLS certificate from ${API_HOST}:443"
  fi

  openssl x509 -in "${tmp_cert}" -noout -checkhost "${API_HOST}" >/dev/null 2>&1 \
    || die "Server certificate does not cover DNS name ${API_HOST}"

  fingerprint="$(openssl x509 -in "${tmp_cert}" -noout -fingerprint -sha256 | sed 's/^.*=//')"
  warn "Trusting certificate received on first connection (TOFU), SHA-256: ${fingerprint}"

  if [[ -d /usr/local/share/ca-certificates ]] && have_cmd update-ca-certificates; then
    trust_file="/usr/local/share/ca-certificates/multidirectory-${API_HOST}.crt"
    install -m 0644 "${tmp_cert}" "${trust_file}"
    update-ca-certificates >/dev/null
  elif have_cmd update-ca-trust; then
    trust_file="/etc/pki/ca-trust/source/anchors/multidirectory-${API_HOST}.crt"
    install -D -m 0644 "${tmp_cert}" "${trust_file}"
    update-ca-trust extract >/dev/null
  else
    die "Unsupported system CA trust store"
  fi

  curl -sS --connect-timeout "${API_CONNECT_TIMEOUT}" --max-time "${API_MAX_TIME}" \
    "https://${API_HOST}/" -o /dev/null \
    || die "TLS verification failed after installing the MultiDirectory certificate"

  log "MultiDirectory TLS certificate installed: ${trust_file}"
)
