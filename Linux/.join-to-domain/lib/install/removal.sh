is_removable_domain_package() {
  local pkg="$1"

  case "$pkg" in
    sssd|sssd-tools|sssd-client|sssd-dbus|libnss-sss|libpam-sss|oddjob|oddjob-mkhomedir)
      return 0
      ;;
    libparsec-db-sssd3|libparsec-mac-db-sssd3|libparsec-mic-db-sssd3|libparsec-aud-db-sssd3|libparsec-cap-db-sssd3)
      return 0
      ;;
    ldap-utils|openldap-clients)
      return 0
      ;;
    krb5-user|krb5-workstation)
      return 0
      ;;
    salt|salt-common|salt-minion)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

is_protected_system_package() {
  local pkg="$1"

  case "$pkg" in
    sudo|openssh-server|ssh|curl|jq|file|ca-certificates)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

build_removal_list() {
  local pkg

  : > "$PACKAGES_TO_REMOVE"
  chmod 600 "$PACKAGES_TO_REMOVE"

  if [[ -f "$PKGS_INSTALLED" ]]; then
    while IFS= read -r pkg; do
      [[ -n "$pkg" ]] || continue

      if is_protected_system_package "$pkg"; then
        warn "Keeping protected package: ${pkg}"
        continue
      fi

      if is_removable_domain_package "$pkg"; then
        echo "$pkg" >> "$PACKAGES_TO_REMOVE"
      else
        warn "Keeping non-domain package: ${pkg}"
      fi
    done < "$PKGS_INSTALLED"
  else
    warn "Package diff manifest not found: ${PKGS_INSTALLED}"
  fi

  if [[ -f "$LOCAL_PKGS_INSTALLED" ]]; then
    while IFS= read -r pkg; do
      [[ -n "$pkg" ]] || continue

      if is_protected_system_package "$pkg"; then
        warn "Keeping protected local package: ${pkg}"
        continue
      fi

      if is_removable_domain_package "$pkg"; then
        echo "$pkg" >> "$PACKAGES_TO_REMOVE"
      else
        warn "Keeping local package outside allowlist: ${pkg}"
      fi
    done < "$LOCAL_PKGS_INSTALLED"
  fi

  sort -u "$PACKAGES_TO_REMOVE" -o "$PACKAGES_TO_REMOVE"
}

remove_packages_deb() {
  mapfile -t packages < "$PACKAGES_TO_REMOVE"

  if (( ${#packages[@]} == 0 )); then
    log "No packages to remove"
    return 0
  fi

  warn "Packages to purge:"
  printf '  - %s\n' "${packages[@]}"

  apt-get purge -y "${packages[@]}"
  apt-get autoremove --purge -y
}

remove_packages_rpm() {
  mapfile -t packages < "$PACKAGES_TO_REMOVE"

  if (( ${#packages[@]} == 0 )); then
    log "No packages to remove"
    return 0
  fi

  warn "Packages to remove:"
  printf '  - %s\n' "${packages[@]}"

  detect_package_manager

  if [[ "${PM}" == "dnf" ]]; then
    dnf remove -y "${packages[@]}"
    dnf autoremove -y || true
  elif [[ "${PM}" == "yum" ]]; then
    yum remove -y "${packages[@]}"
    yum autoremove -y || true
  elif [[ "${PM}" == "apt-get" ]]; then
    apt-get purge -y "${packages[@]}"
    apt-get autoremove --purge -y
  else
    die "No supported package manager found"
  fi
}
