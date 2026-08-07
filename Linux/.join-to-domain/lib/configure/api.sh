api_auth_cookie() {
  local user="$1"
  local pass="$2"
  local tmp_headers tmp_body http_code curl_rc cookie detail

  tmp_headers="$(mktemp "${TMPDIR:-/tmp}/md-auth-headers.XXXXXX")"
  tmp_body="$(mktemp "${TMPDIR:-/tmp}/md-auth-body.XXXXXX")"
  chmod 600 "$tmp_headers" "$tmp_body"

  set +e
  http_code="$(
    curl -sS -X POST "https://${API_HOST}/api/auth/" \
      --connect-timeout "${API_CONNECT_TIMEOUT}" \
      --max-time "${API_MAX_TIME}" \
      -H "accept: application/json" \
      -H "Content-Type: application/x-www-form-urlencoded" \
      --data-urlencode "username=${user}" \
      --data-urlencode "password=${pass}" \
      -D "$tmp_headers" \
      -o "$tmp_body" \
      -w '%{http_code}'
  )"
  curl_rc=$?
  set -e

  if [[ "$curl_rc" -ne 0 || ! "$http_code" =~ ^2[0-9][0-9]$ ]]; then
    detail="$(tr '\r\n' ' ' < "$tmp_body" | cut -c1-1000)"
    log "Authentication failed: curl exit ${curl_rc}, HTTP ${http_code:-000}; response=${detail:-empty}"
    rm -f "$tmp_headers" "$tmp_body"
    return 1
  fi

  cookie="$(
    awk '
      {
        line=$0
      }
      tolower(line) ~ /^set-cookie:[[:space:]]*id=/ {
        sub(/^[^:]+:/, "", line)
        sub(/^[[:space:]]*/, "", line)
        sub(/^[^=]*=/, "", line)
        sub(/;.*/, "", line)
        gsub(/\r/, "", line)
        print line
        exit
      }
    ' "$tmp_headers"
  )"

  rm -f "$tmp_headers" "$tmp_body"

  if [[ -z "$cookie" ]]; then
    log "Authentication response was successful but did not contain the id cookie"
    return 1
  fi

  printf '%s' "$cookie"
}

api_validate_session() {
  local cookie="$1"
  local tmp_body http_code curl_rc detail

  tmp_body="$(mktemp "${TMPDIR:-/tmp}/md-auth-check.XXXXXX")"
  chmod 600 "$tmp_body"

  set +e
  http_code="$(
    curl -sS -X GET "https://${API_HOST}/api/auth/me" \
      --connect-timeout "${API_CONNECT_TIMEOUT}" \
      --max-time "${API_MAX_TIME}" \
      -H "accept: application/json" \
      -H "Cookie: id=${cookie}" \
      -o "$tmp_body" \
      -w '%{http_code}'
  )"
  curl_rc=$?
  set -e

  if [[ "$curl_rc" -eq 0 && "$http_code" =~ ^2[0-9][0-9]$ ]]; then
    rm -f "$tmp_body"
    return 0
  fi

  detail="$(tr '\r\n' ' ' < "$tmp_body" | cut -c1-1000)"
  log "Authentication session validation failed: curl exit ${curl_rc}, HTTP ${http_code:-000}; response=${detail:-empty}"
  rm -f "$tmp_body"
  return 1
}

api_search() {
  local cookie="$1"
  local base_object="$2"
  local scope="$3"
  local filter="$4"
  local attrs_json="$5"
  local size_limit="${6:-5}"
  local tmp_body http_code curl_rc detail
  local -a cookie_header=()

  if [[ -n "$cookie" ]]; then
    cookie_header=(-H "Cookie: id=${cookie}")
  fi

  tmp_body="$(mktemp "${TMPDIR:-/tmp}/md-api-search.XXXXXX")"
  chmod 600 "$tmp_body"

  set +e
  http_code="$(
    curl -sS -X POST "https://${API_HOST}/api/entry/search" \
      --connect-timeout "${API_CONNECT_TIMEOUT}" \
      --max-time "${API_MAX_TIME}" \
      -H "accept: application/json" \
      "${cookie_header[@]}" \
      -H "Content-Type: application/json" \
      -d "{
        \"base_object\": \"${base_object}\",
        \"scope\": ${scope},
        \"deref_aliases\": 0,
        \"size_limit\": ${size_limit},
        \"time_limit\": 0,
        \"types_only\": false,
        \"filter\": \"${filter}\",
        \"attributes\": ${attrs_json}
      }" \
      -o "$tmp_body" \
      -w '%{http_code}'
  )"
  curl_rc=$?
  set -e

  if [[ "$curl_rc" -ne 0 ]]; then
    log "Entry search transport failure: curl exit ${curl_rc}, HTTP ${http_code:-000}"
    rm -f "$tmp_body"
    return 1
  fi

  if [[ ! "$http_code" =~ ^2[0-9][0-9]$ ]]; then
    detail="$(tr '\r\n' ' ' < "$tmp_body" | cut -c1-1000)"
    log "Entry search failed: HTTP ${http_code}; response=${detail:-empty}"
    rm -f "$tmp_body"
    return 1
  fi

  if ! jq -e . "$tmp_body" >/dev/null 2>&1; then
    detail="$(tr '\r\n' ' ' < "$tmp_body" | cut -c1-1000)"
    log "Entry search returned invalid JSON: HTTP ${http_code}; response=${detail:-empty}"
    rm -f "$tmp_body"
    return 1
  fi

  cat "$tmp_body"
  rm -f "$tmp_body"
}

api_response_attribute() {
  local attribute="$1"

  jq -r --arg wanted "$attribute" '
    [
      .. | objects |
      if (((.type? // .name? // "") | tostring | ascii_downcase) == ($wanted | ascii_downcase)) then
        (.vals? // .values? // empty) |
        if type == "array" then .[0] else . end
      else
        to_entries[]? |
        select((.key | ascii_downcase) == ($wanted | ascii_downcase)) |
        .value |
        if type == "array" then .[0] else . end
      end
    ]
    | map(select(. != null and . != ""))
    | .[0] // empty
  '
}

api_rootdse_default_nc() {
  local cookie="$1"
  local resp nc

  if ! resp="$(api_rootdse_response "$cookie")"; then
    return 1
  fi

  nc="$(printf '%s' "$resp" | api_response_attribute "defaultNamingContext")"
  [[ -n "$nc" ]] || nc="$(printf '%s' "$resp" | api_response_attribute "rootDomainNamingContext")"
  [[ -n "$nc" ]] || nc="$(printf '%s' "$resp" | api_response_attribute "namingContexts")"

  printf '%s' "$nc"
}

dn_to_domain() {
  awk -F',' '
    {
      out="";
      for (i=1; i<=NF; i++) {
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", $i);
        if ($i ~ /^dc=/ || $i ~ /^DC=/) {
          sub(/^[dD][cC]=/, "", $i);
          out = (out == "" ? $i : out "." $i);
        }
      }
      print tolower(out);
    }
  '
}

api_rootdse_response() {
  local cookie="${1:-}"

  api_search "$cookie" "" 0 "(objectClass=*)" \
    '["dnsHostName","rootDomainNamingContext","defaultNamingContext","namingContexts","subschemaSubentry","supportedLDAPVersion","supportedSASLMechanisms","supportedExtension","supportedControl","supportedFeatures","vendorName","name","vendorVersion","objectClass"]' \
    0
}

api_rootdse_domain() {
  local cookie="$1"
  local resp dom nc

  if ! resp="$(api_rootdse_response "$cookie")"; then
    return 1
  fi

  dom="$(printf '%s' "$resp" | api_response_attribute "dnsHostName")"

  [[ -n "$dom" ]] || dom="$(printf '%s' "$resp" | api_response_attribute "dnsDomainName")"

  [[ -n "$dom" ]] || dom="$(printf '%s' "$resp" | api_response_attribute "dnsForestName")"

  if [[ -z "$dom" ]]; then
    nc="$(printf '%s' "$resp" | api_response_attribute "defaultNamingContext")"
    [[ -n "$nc" ]] || nc="$(printf '%s' "$resp" | api_response_attribute "rootDomainNamingContext")"
    [[ -n "$nc" ]] || nc="$(printf '%s' "$resp" | api_response_attribute "namingContexts")"
    [[ -n "$nc" ]] && dom="$(printf '%s' "$nc" | dn_to_domain)"
  fi

  if [[ -z "$dom" ]]; then
    log "RootDSE response contains no usable domain attributes: $(printf '%s' "$resp" | tr '\r\n' ' ' | cut -c1-1500)"
  fi

  printf '%s' "$dom"
}

api_principal_add() {
  local cookie="$1"
  local spn="$2"
  local primary="${spn%%/*}"
  local instance="${spn#*/}"

  curl -sS -X POST "https://${API_HOST}/api/kerberos/principal/add" \
    --connect-timeout "${API_CONNECT_TIMEOUT}" \
    --max-time "${API_MAX_TIME}" \
    -H "accept: application/json" \
    -H "Content-Type: application/json" \
    -H "Cookie: id=${cookie}" \
    -d "{\"primary\":\"${primary}\",\"instance\":\"${instance}\"}" \
    -o /dev/null \
    -w '%{http_code}' 2>/dev/null
}

response_content_type() {
  local headers="$1"

  awk -F': *' '
    BEGIN { IGNORECASE=1 }
    /^content-type:/ {
      gsub(/\r$/, "", $2)
      value=$2
    }
    END { print value }
  ' "$headers" 2>/dev/null || true
}

api_ktadd_download() {
  local cookie="$1"
  shift
  local spn body sep http_code content_type detail
  local tmp_dir tmp_headers tmp_body

  mkdir -p "${MD_STATE_DIR}"
  chmod 700 "${MD_STATE_DIR}"
  tmp_dir="$(mktemp -d "${MD_STATE_DIR}/ktadd.XXXXXX")"
  chmod 700 "$tmp_dir"
  tmp_headers="${tmp_dir}/headers"
  tmp_body="${tmp_dir}/keytab"
  : > "$tmp_headers"
  : > "$tmp_body"
  chmod 600 "$tmp_headers" "$tmp_body"
  trap 'rm -rf "${tmp_dir:-}"; trap - RETURN' RETURN

  if [[ "${EDITION}" == "community" ]]; then
    log "Community: registering principals"
    body="["
    sep=""
    for spn in "$@"; do
      log "${spn}: HTTP $(api_principal_add "${cookie}" "${spn}")"
      body="${body}${sep}\"${spn}@${REALM}\""
      sep=","
    done
    body="${body}]"
  else
    body="{\"names\":["
    sep=""
    for spn in "$@"; do
      body="${body}${sep}\"${spn}\""
      sep=","
    done
    body="${body}],\"is_rand_key\":true}"
  fi

  log "Keytab API endpoint: https://${API_HOST}/api/kerberos/ktadd"
  log "Keytab principals: $*"

  http_code="$(
    curl -sS \
      --connect-timeout "${API_CONNECT_TIMEOUT}" \
      --max-time "${API_MAX_TIME}" \
      -D "$tmp_headers" \
      -o "$tmp_body" \
      -X POST "https://${API_HOST}/api/kerberos/ktadd" \
      -H "accept: application/octet-stream" \
      -H "Content-Type: application/json" \
      -H "Cookie: id=${cookie}" \
      -d "${body}" \
      -w '%{http_code}' 2>/dev/null
  )" || http_code="000"

  content_type="$(response_content_type "$tmp_headers")"
  log "Keytab API response: HTTP ${http_code}, content-type=${content_type:-unknown}"

  if [[ ! "$http_code" =~ ^2[0-9][0-9]$ ]]; then
    detail="$(
      jq -r '
        if type == "object" then
          (.detail // .message // .error // tostring)
        else
          tostring
        end
      ' "$tmp_body" 2>/dev/null || head -n 20 "$tmp_body" 2>/dev/null || true
    )"

    rm -rf "$tmp_dir"
    trap - RETURN
    die "Keytab retrieval failed. HTTP ${http_code}: ${detail}"
  fi

  if printf '%s' "$content_type" | grep -Eiq 'json|text|html'; then
    warn "API returned non-binary keytab:"
    head -n 60 "$tmp_body" || true
    rm -rf "$tmp_dir"
    trap - RETURN
    die "keytab was not received as a binary file"
  fi

  if [[ ! -s "$tmp_body" ]]; then
    rm -rf "$tmp_dir"
    trap - RETURN
    die "keytab was not received: empty API response body"
  fi

  if file "$tmp_body" 2>/dev/null | grep -Ei 'json|text|html' >/dev/null; then
    warn "API returned non-binary keytab:"
    head -n 60 "$tmp_body" || true
    rm -rf "$tmp_dir"
    trap - RETURN
    die "keytab was not received as a binary file"
  fi

  md_backup_once /etc/krb5.keytab
  install -m 600 -o root -g root "$tmp_body" /etc/krb5.keytab
  md_track /etc/krb5.keytab

  log "Keytab installed: /etc/krb5.keytab"
}

api_update_many_replace_uac() {
  local cookie="$1"
  local object_dn="$2"
  local uac_value="$3"
  local payload resp http_code body

  payload="$(jq -n \
    --arg object "$object_dn" \
    --arg uac "$uac_value" \
    '[
      {
        object: $object,
        changes: [
          {
            operation: 2,
            modification: {
              type: "userAccountControl",
              vals: [$uac]
            }
          }
        ]
      }
    ]'
  )"

  resp="$(
    curl -sS -w "\n%{http_code}" \
      --connect-timeout "${API_CONNECT_TIMEOUT}" \
      --max-time "${API_MAX_TIME}" \
      -X PATCH "https://${API_HOST}/api/entry/update_many" \
      -H 'accept: application/json' \
      -H 'Content-Type: application/json' \
      -H "Cookie: id=${cookie}" \
      -d "${payload}" 2>&1
  )" || true

  http_code="$(echo "$resp" | tail -n1)"
  body="$(echo "$resp" | sed '$d')"

  if [[ "$http_code" =~ ^2[0-9][0-9]$ ]]; then
    return 0
  fi

  warn "Failed to update userAccountControl for ${object_dn}. HTTP ${http_code}: ${body}"
  return 1
}

api_find_computer_object_dn() {
  local cookie="$1"
  local computer_ou="$2"
  local computer_name="$3"
  local resp dn

  resp="$(
    api_search "$cookie" "$computer_ou" 2 "(&(objectClass=computer)(cn=${computer_name}))" "[\"cn\",\"userAccountControl\"]" 2>&1
  )" || {
    return 2
  }

  dn="$(printf '%s' "$resp" | jq -r '.search_result[0].object_name // empty' 2>/dev/null || true)"
  [[ -n "$dn" ]] || return 1

  printf '%s' "$dn"
  return 0
}

enable_computer_account() {
  local object_dn="$1"

  api_update_many_replace_uac "${access_token}" "${object_dn}" "4096" \
    || die "Failed to enable computer account: ${object_dn}"

}

enable_computer_account_if_disabled() {
  local object_dn="$1"
  local current_uac="$2"
  local enabled_uac

  if [[ ! "$current_uac" =~ ^[0-9]+$ ]]; then
    warn "Cannot determine userAccountControl for ${object_dn}; computer account enable skipped"
    return 0
  fi

  if (( (current_uac & 2) == 0 )); then
    log "Computer account already enabled: ${object_dn}"
    return 0
  fi

  enabled_uac=$((current_uac & ~2))
  [[ "$enabled_uac" -gt 0 ]] || enabled_uac=4096

  info "Computer account is disabled, enabling it"
  api_update_many_replace_uac "${access_token}" "${object_dn}" "${enabled_uac}" \
    || die "Failed to enable computer account: ${object_dn}"

  log "Computer account enabled: ${object_dn}"
}

disable_computer_account_on_leave() {
  local object_dn expected_dn lookup_rc

  [[ -n "${HOSTNAME:-}" ]] || {
    warn "HOSTNAME is unknown, computer account disable skipped"
    return 0
  }

  [[ -n "${LDAP_COMPUTER_OU:-}" ]] || {
    warn "LDAP_COMPUTER_OU is unknown, computer account disable skipped"
    return 0
  }

  [[ -n "${access_token:-}" ]] || {
    warn "API access token is missing, computer account disable skipped"
    return 0
  }

  expected_dn="cn=${HOSTNAME},${LDAP_COMPUTER_OU}"

  if object_dn="$(api_find_computer_object_dn "${access_token}" "${LDAP_COMPUTER_OU}" "${HOSTNAME}")"; then
    lookup_rc=0
  else
    lookup_rc=$?
  fi

  case "$lookup_rc" in
    0)
      ;;
    1)
      warn "Computer object not found in LDAP: ${expected_dn}"
      warn "Skipping remote computer disable"
      return 0
      ;;
    2)
      warn "Timeout while checking computer object, skipping remote disable"
      return 0
      ;;
    *)
      warn "Failed to check computer object, skipping remote disable: ${expected_dn}"
      return 0
      ;;
  esac

  info "Disabling computer account"
  if api_update_many_replace_uac "${access_token}" "${object_dn}" "4098"; then
    log "Computer account disabled: ${object_dn}"
  else
    warn "Computer account was not disabled on server side; local leave will continue"
  fi
}
