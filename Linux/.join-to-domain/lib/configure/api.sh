api_auth_cookie() {
  local user="$1"
  local pass="$2"

  curl -k -sS -X POST "https://${API_HOST}/api/auth/" \
    --connect-timeout "${API_CONNECT_TIMEOUT}" \
    --max-time "${API_MAX_TIME}" \
    -H "accept: application/json" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    --data-urlencode "username=${user}" \
    --data-urlencode "password=${pass}" \
    -D - -o /dev/null \
    | awk -F'id=|;' 'BEGIN{IGNORECASE=1} /set-cookie:[[:space:]]*id=/{print $2; exit}' \
    | tr -d '\r\n'
}

api_search() {
  local cookie="$1"
  local base_object="$2"
  local scope="$3"
  local filter="$4"
  local attrs_json="$5"

  curl -k -sS -X POST "https://${API_HOST}/api/entry/search" \
    --connect-timeout "${API_CONNECT_TIMEOUT}" \
    --max-time "${API_MAX_TIME}" \
    -H "accept: application/json" \
    -H "Cookie: id=${cookie}" \
    -H "Content-Type: application/json" \
    -d "{
      \"base_object\": \"${base_object}\",
      \"scope\": ${scope},
      \"deref_aliases\": 0,
      \"size_limit\": 5,
      \"time_limit\": 0,
      \"types_only\": false,
      \"filter\": \"${filter}\",
      \"attributes\": ${attrs_json}
    }"
}

api_rootdse_default_nc() {
  local cookie="$1"
  local resp

  resp="$(api_search "$cookie" "" 0 "(objectClass=*)" "[\"defaultNamingContext\"]")"

  printf '%s' "$resp" | jq -r '
    (.search_result[0].partial_attributes[]? | select(.type=="defaultNamingContext") | .vals[0]) // empty
  '
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

api_rootdse_domain() {
  local cookie="$1"
  local resp dom nc

  resp="$(api_search "$cookie" "" 0 "(objectClass=*)" "[\"dnsDomainName\",\"dnsForestName\",\"dnsHostName\",\"defaultNamingContext\"]")"

  dom="$(printf '%s' "$resp" | jq -r '
    (.search_result[0].partial_attributes[]? | select(.type=="dnsDomainName") | .vals[0]) // empty
  ')"

  [[ -n "$dom" ]] || dom="$(printf '%s' "$resp" | jq -r '
    (.search_result[0].partial_attributes[]? | select(.type=="dnsForestName") | .vals[0]) // empty
  ')"

  if [[ -z "$dom" ]]; then
    nc="$(printf '%s' "$resp" | jq -r '
      (.search_result[0].partial_attributes[]? | select(.type=="defaultNamingContext") | .vals[0]) // empty
    ')"
    [[ -n "$nc" ]] && dom="$(printf '%s' "$nc" | dn_to_domain)"
  fi

  printf '%s' "$dom"
}

api_principal_add() {
  local cookie="$1"
  local spn="$2"
  local primary="${spn%%/*}"
  local instance="${spn#*/}"

  curl -k -sS -X POST "https://${API_HOST}/api/kerberos/principal/add" \
    --connect-timeout "${API_CONNECT_TIMEOUT}" \
    --max-time "${API_MAX_TIME}" \
    -H "accept: application/json" \
    -H "Content-Type: application/json" \
    -H "Cookie: id=${cookie}" \
    -d "{\"primary\":\"${primary}\",\"instance\":\"${instance}\"}" \
    -o /tmp/md-principal-add.body \
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

  rm -f /tmp/md-ktadd.hdr /tmp/md-ktadd.body /etc/krb5.keytab

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
    curl -k -sS \
      --connect-timeout "${API_CONNECT_TIMEOUT}" \
      --max-time "${API_MAX_TIME}" \
      -D /tmp/md-ktadd.hdr \
      -o /tmp/md-ktadd.body \
      -X POST "https://${API_HOST}/api/kerberos/ktadd" \
      -H "accept: application/octet-stream" \
      -H "Content-Type: application/json" \
      -H "Cookie: id=${cookie}" \
      -d "${body}" \
      -w '%{http_code}' 2>/dev/null
  )" || http_code="000"

  content_type="$(response_content_type /tmp/md-ktadd.hdr)"
  log "Keytab API response: HTTP ${http_code}, content-type=${content_type:-unknown}"

  if [[ ! "$http_code" =~ ^2[0-9][0-9]$ ]]; then
    detail="$(
      jq -r '
        if type == "object" then
          (.detail // .message // .error // tostring)
        else
          tostring
        end
      ' /tmp/md-ktadd.body 2>/dev/null || head -n 20 /tmp/md-ktadd.body 2>/dev/null || true
    )"

    die "Keytab retrieval failed. HTTP ${http_code}: ${detail}"
  fi

  if printf '%s' "$content_type" | grep -Eiq 'json|text|html'; then
    warn "API returned non-binary keytab:"
    head -n 60 /tmp/md-ktadd.body || true
    die "keytab was not received as a binary file"
  fi

  if [[ ! -s /tmp/md-ktadd.body ]]; then
    die "keytab was not received: empty API response body"
  fi

  if file /tmp/md-ktadd.body 2>/dev/null | grep -Ei 'json|text|html' >/dev/null; then
    warn "API returned non-binary keytab:"
    head -n 60 /tmp/md-ktadd.body || true
    die "keytab was not received as a binary file"
  fi

  install -m 600 -o root -g root /tmp/md-ktadd.body /etc/krb5.keytab
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
    curl -k -sS -w "\n%{http_code}" \
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

  warn "Disabling computer account: ${object_dn}"
  if api_update_many_replace_uac "${access_token}" "${object_dn}" "4098"; then
    log "Computer account disabled: ${object_dn}"
  else
    warn "Computer account was not disabled on server side; local leave will continue"
  fi
}

