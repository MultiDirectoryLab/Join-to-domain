# User-facing English/Russian translations shared by install and configure.
tr_text() {
  local key="$1"

  case "${MD_UI_LANG:-en}:${key}" in
    ru:language.title) printf 'Выберите язык / Select language' ;;
    ru:language.ru) printf 'Русский' ;;
    ru:language.en) printf 'English' ;;
    ru:menu.title) printf 'Присоединение к домену' ;;
    ru:menu.install) printf 'Установить необходимые пакеты' ;;
    ru:menu.join) printf 'Присоединиться к домену' ;;
    ru:menu.rejoin) printf 'Повторно присоединить к домену' ;;
    ru:menu.leave) printf 'Выйти из домена' ;;
    ru:menu.renew_certificate) printf 'Обновить сертификат' ;;
    ru:menu.reboot) printf 'Перезагрузить компьютер' ;;
    ru:menu.exit) printf 'Выход' ;;
    ru:prompt.select) printf 'Выберите пункт' ;;
    ru:prompt.md_server) printf 'Введите адрес сервера MD (IPv4/DOMAIN/FQDN), например 10.1.1.1/domain.ru/dc1.domain.ru:' ;;
    ru:prompt.md_server_fqdn) printf 'Введите FQDN домена/сервера MD:' ;;
    ru:prompt.dns_servers) printf 'Введите IP-адреса DNS-серверов через запятую [пример: 8.8.8.8 или 8.8.8.8,1.1.1.1]:' ;;
    ru:prompt.press_enter) printf 'Нажмите Enter, чтобы вернуться в главное меню...' ;;
    ru:prompt.reboot) printf 'Вы уверены, что хотите перезагрузить компьютер?' ;;
    ru:answer.yes) printf 'Да' ;;
    ru:answer.no) printf 'Нет' ;;
    ru:status.exiting) printf 'Выход' ;;
    ru:status.rebooting) printf 'Перезагрузка компьютера...' ;;
    ru:error.reboot) printf 'Не удалось перезагрузить компьютер.' ;;
    ru:error.empty_menu) printf 'Пустой ввод. Выберите пункт меню.' ;;
    ru:error.invalid_menu) printf 'Неверный пункт. Выберите 1, 2, 3, 4, 5, 6 или 7.' ;;
    ru:error.invalid_12) printf 'Неверный пункт. Выберите 1 или 2.' ;;
    ru:status.return_menu) printf 'Возврат в главное меню.' ;;
    ru:leave.title) printf 'Обнаружена конфигурация домена.' ;;
    ru:leave.description) printf 'Будет выполнен безопасный выход из MultiDirectory.' ;;
    ru:leave.keep) printf 'PAM, NSS, SSH, имя компьютера и hosts будут сохранены, если изменение не пройдёт проверки безопасности.' ;;
    ru:leave.continue) printf 'Продолжить безопасный выход' ;;
    ru:leave.cancel) printf 'Отмена и возврат в главное меню' ;;
    *:language.title) printf 'Select language / Выберите язык' ;;
    *:language.ru) printf 'Русский' ;;
    *:language.en) printf 'English' ;;
    *:menu.title) printf 'Join to Domain' ;;
    *:menu.install) printf 'Install required packages' ;;
    *:menu.join) printf 'Join domain' ;;
    *:menu.rejoin) printf 'Rejoin domain' ;;
    *:menu.leave) printf 'Leave domain' ;;
    *:menu.renew_certificate) printf 'Renew certificate' ;;
    *:menu.reboot) printf 'Reboot PC' ;;
    *:menu.exit) printf 'Exit' ;;
    *:prompt.select) printf 'Select an option' ;;
    *:prompt.md_server) printf 'Enter MD server address (IPv4/DOMAIN/FQDN), for example 10.1.1.1/domain.ru/dc1.domain.ru:' ;;
    *:prompt.md_server_fqdn) printf 'Enter MD domain/server FQDN:' ;;
    *:prompt.dns_servers) printf 'Enter DNS server IP addresses separated by commas [example: 8.8.8.8 or 8.8.8.8,1.1.1.1]:' ;;
    *:prompt.press_enter) printf 'Press Enter to return to the main menu...' ;;
    *:prompt.reboot) printf 'Are you sure you want to reboot this PC?' ;;
    *:answer.yes) printf 'Yes' ;;
    *:answer.no) printf 'No' ;;
    *:status.exiting) printf 'Exiting' ;;
    *:status.rebooting) printf 'Rebooting PC...' ;;
    *:error.reboot) printf 'Failed to reboot the system.' ;;
    *:error.empty_menu) printf 'Empty input. Please select a menu item.' ;;
    *:error.invalid_menu) printf 'Invalid option. Please select 1, 2, 3, 4, 5, 6 or 7.' ;;
    *:error.invalid_12) printf 'Invalid option. Please select 1 or 2.' ;;
    *:status.return_menu) printf 'Returning to main menu.' ;;
    *:leave.title) printf 'Domain-related configuration was found.' ;;
    *:leave.description) printf 'This will perform a safe MultiDirectory leave.' ;;
    *:leave.keep) printf 'PAM, NSS, SSH, hostname and hosts files will be kept unless a change passes safety checks.' ;;
    *:leave.continue) printf 'Continue safe leave' ;;
    *:leave.cancel) printf 'Cancel and return to main menu' ;;
    *) printf '%s' "$key" ;;
  esac
}

ui_text() {
  local english="$1"
  local russian="$2"

  if [[ "${MD_UI_LANG:-en}" == "ru" ]]; then
    printf '%s' "$russian"
  else
    printf '%s' "$english"
  fi
}

# Translates legacy one-argument status messages. New messages should prefer
# ui_text, but the central formatter keeps every module Russian when language 1
# is selected, including package installation and rollback paths.
runtime_text() {
  local text="$1"
  [[ "${MD_UI_LANG:-en}" == "ru" ]] || { printf '%s' "$text"; return; }
  # Messages already selected by ui_text/tr_text must pass through unchanged.
  [[ "$text" =~ [АБВГДЕЁЖЗИЙКЛМНОПРСТУФХЦЧШЩЪЫЬЭЮЯабвгдеёжзийклмнопрстуфхцчшщъыьэюя] ]] \
    && { printf '%s' "$text"; return; }

  case "$text" in
    "All required dependencies are installed") printf 'Все необходимые зависимости установлены' ;;
    "Missing required dependencies") printf 'Отсутствуют необходимые зависимости' ;;
    "Required internal component not found") printf 'Не найден обязательный внутренний компонент' ;;
    "No packages to install") printf 'Нет пакетов для установки' ;;
    "Updating package index") printf 'Обновление индекса пакетов' ;;
    "Installing required packages") printf 'Установка необходимых пакетов' ;;
    "Package installation completed") printf 'Установка пакетов завершена' ;;
    "One or more packages failed verification") printf 'Один или несколько пакетов не прошли проверку' ;;
    "Running package installation") printf 'Запуск установки пакетов' ;;
    "Installer returned an empty dependency list") printf 'Установщик вернул пустой список зависимостей' ;;
    "Input contains invalid characters. Please enter the value again.") printf 'Ввод содержит недопустимые символы. Повторите ввод.' ;;
    "No supported package manager found"*) printf 'Не найден поддерживаемый менеджер пакетов%s' "${text#No supported package manager found}" ;;
    "Unsupported OS: "*) printf 'Неподдерживаемая ОС: %s' "${text#Unsupported OS: }" ;;
    "Run as root: "*) printf 'Запустите с правами root: %s' "${text#Run as root: }" ;;
    "Command not found: "*) printf 'Команда не найдена: %s' "${text#Command not found: }" ;;
    "File not found: "*) printf 'Файл не найден: %s' "${text#File not found: }" ;;
    "File is empty: "*) printf 'Файл пуст: %s' "${text#File is empty: }" ;;
    "Directory not found: "*) printf 'Каталог не найден: %s' "${text#Directory not found: }" ;;
    "Installed: "*) printf 'Установлено: %s' "${text#Installed: }" ;;
    "Package is not installed after installation attempt: "*) printf 'Пакет не установлен после попытки установки: %s' "${text#Package is not installed after installation attempt: }" ;;
    "DNS resolution failed: "*) printf 'Ошибка разрешения DNS: %s' "${text#DNS resolution failed: }" ;;
    "API_HOST is empty in environment") printf 'API_HOST в файле окружения не задан' ;;
    "Invalid API_HOST in environment: "*) printf 'Некорректный API_HOST в файле окружения: %s' "${text#Invalid API_HOST in environment: }" ;;
    "Login and password must be filled") printf 'Логин и пароль должны быть заполнены' ;;
    "Saved domain is unavailable"*) printf 'Сохранённый домен недоступен; он будет определён после аутентификации' ;;
    "Saved API host is unavailable"*) printf 'Сохранённый адрес API недоступен; потребуется интерактивный ввод' ;;
    "Failed to authenticate domain administrator") printf 'Не удалось аутентифицировать администратора домена' ;;
    "Failed to detect domain via RootDSE") printf 'Не удалось определить домен через RootDSE' ;;
    "Domain mismatch."*) printf 'Домен не совпадает.%s' "${text#Domain mismatch.}" ;;
    "Active join backup is missing or corrupted") printf 'Активная резервная копия присоединения отсутствует или повреждена' ;;
    "Original configuration could not be fully restored") printf 'Не удалось полностью восстановить исходную конфигурацию' ;;
    "Restored PAM/NSS/SSH configuration validation failed") printf 'Восстановленная конфигурация PAM/NSS/SSH не прошла проверку' ;;
    "Error in SSH daemon configuration") printf 'Ошибка в конфигурации SSH-сервера' ;;
    "PAM restore validation failed: local authentication module missing") printf 'Ошибка проверки восстановленного PAM: отсутствует модуль локальной аутентификации' ;;
    "PAM restore validation failed: "*) printf 'Ошибка проверки восстановленного PAM: %s' "${text#PAM restore validation failed: }" ;;
    "NetworkManager DNS state was not fully restored") printf 'Состояние DNS NetworkManager восстановлено не полностью' ;;
    "authselect state was not fully restored") printf 'Состояние authselect восстановлено не полностью' ;;
    "SSSD socket state was not fully restored") printf 'Состояние сокетов SSSD восстановлено не полностью' ;;
    "Required internal helper is not loaded: "*) printf 'Не загружена обязательная внутренняя функция: %s' "${text#Required internal helper is not loaded: }" ;;
    "Failed to create a safe pre-join backup") printf 'Не удалось создать безопасную резервную копию перед присоединением' ;;
    "No backup transaction is loaded for "*) printf 'Не загружена транзакция резервного копирования: %s' "${text#No backup transaction is loaded for }" ;;
    "Failed to back up: "*) printf 'Не удалось создать резервную копию: %s' "${text#Failed to back up: }" ;;
    "Invalid keytab") printf 'Некорректный keytab' ;;
    "Kerberos keytab authentication failed") printf 'Аутентификация Kerberos по keytab завершилась ошибкой' ;;
    "LDAP GSSAPI authentication failed"*) printf 'Аутентификация LDAP GSSAPI завершилась ошибкой%s' "${text#LDAP GSSAPI authentication failed}" ;;
    "LDAP Kerberos service principal is unavailable: "*) printf 'Недоступен Kerberos principal службы LDAP: %s' "${text#LDAP Kerberos service principal is unavailable: }" ;;
    "Failed to check whether computer object exists in LDAP") printf 'Не удалось проверить наличие объекта компьютера в LDAP' ;;
    "Computer already exists in LDAP, creation skipped") printf 'Компьютер уже существует в LDAP, создание пропущено' ;;
    "Failed to create computer object "*) printf 'Не удалось создать объект компьютера %s' "${text#Failed to create computer object }" ;;
    "PAM file not found: "*) printf 'Файл PAM не найден: %s' "${text#PAM file not found: }" ;;
    "Failed to patch PAM file: "*) printf 'Не удалось изменить файл PAM: %s' "${text#Failed to patch PAM file: }" ;;
    "NSS configuration not found: "*) printf 'Конфигурация NSS не найдена: %s' "${text#NSS configuration not found: }" ;;
    "SSSD configuration validated") printf 'Конфигурация SSSD проверена' ;;
    "SSSD configuration validation failed") printf 'Конфигурация SSSD не прошла проверку' ;;
    "sssctl not found, SSSD config validation skipped") printf 'sssctl не найден, проверка конфигурации SSSD пропущена' ;;
    "sudoers validation failed") printf 'Конфигурация sudoers не прошла проверку' ;;
    "visudo not found, sudoers validation skipped") printf 'visudo не найден, проверка sudoers пропущена' ;;
    "Backing up Astra SE configuration") printf 'Создание резервной копии конфигурации Astra SE' ;;
    "Astra SE configuration backup completed") printf 'Резервная копия конфигурации Astra SE создана' ;;
    "Applying Astra SE SSSD/PARSEC configuration") printf 'Применение конфигурации SSSD/PARSEC для Astra SE' ;;
    "Astra SE configuration completed") printf 'Настройка Astra SE завершена' ;;
    "Astra Linux SE detected: preserving existing SSSD snippets") printf 'Обнаружена Astra Linux SE: существующие фрагменты конфигурации SSSD будут сохранены' ;;
    "Keytab retrieval failed."*) printf 'Не удалось получить keytab.%s' "${text#Keytab retrieval failed.}" ;;
    "keytab was not received"*) printf 'Keytab не получен%s' "${text#keytab was not received}" ;;
    "Failed to enable computer account: "*) printf 'Не удалось включить учётную запись компьютера: %s' "${text#Failed to enable computer account: }" ;;
    "Computer account is disabled, enabling it") printf 'Учётная запись компьютера отключена, выполняется включение' ;;
    "Disabling computer account") printf 'Отключение учётной записи компьютера' ;;
    "Computer account was not disabled"*) printf 'Учётная запись компьютера не была отключена%s' "${text#Computer account was not disabled}" ;;
    "Failed to refresh API session before Salt key operations") printf 'Не удалось обновить API-сессию перед операциями с ключом Salt' ;;
    "Salt minion id is not a UUID "*) printf 'Идентификатор Salt minion не является UUID %s' "${text#Salt minion id is not a UUID }" ;;
    "Failed to request Salt key deletion for "*) printf 'Не удалось запросить удаление ключа Salt для %s' "${text#Failed to request Salt key deletion for }" ;;
    "Salt key deletion returned HTTP "*) printf 'Удаление ключа Salt вернуло HTTP %s' "${text#Salt key deletion returned HTTP }" ;;
    "Continuing without blocking the current operation") printf 'Текущая операция будет продолжена' ;;
    "API access token is missing"*) printf 'Токен API отсутствует; очистка Salt пропущена' ;;
    "Computer LDAP path is unknown"*) printf 'Путь компьютера в LDAP неизвестен; очистка Salt пропущена' ;;
    "Failed to get computer objectGUID"*) printf 'Не удалось получить objectGUID компьютера; очистка Salt пропущена' ;;
    "Computer objectGUID not found"*) printf 'objectGUID компьютера не найден; очистка Salt пропущена' ;;
    "Deleting Salt key on master for minion id: "*) printf 'Удаление ключа Salt на master для minion: %s' "${text#Deleting Salt key on master for minion id: }" ;;
    "Custom Salt pkg module not found"*) printf 'Пользовательский модуль Salt pkg не найден; установка пропущена' ;;
    "salt-call not found"*) printf 'salt-call не найден; обновление модулей Salt пропущено' ;;
    "Failed to get objectGUID") printf 'Не удалось получить objectGUID' ;;
    "Failed to get Salt master_finger") printf 'Не удалось получить master_finger Salt' ;;
    "Salt minion diagnostics:") printf 'Диагностика Salt minion:' ;;
    "salt-minion binary not found in PATH") printf 'Исполняемый файл salt-minion не найден в PATH' ;;
    "Failed to restart salt-minion.service") printf 'Не удалось перезапустить salt-minion.service' ;;
    "Existing join state was created without a pre-join backup reference") printf 'Существующее состояние присоединения создано без ссылки на исходную резервную копию' ;;
    "Recovery rejoin failed with exit code "*) printf 'Восстановительное присоединение завершилось с кодом %s' "${text#Recovery rejoin failed with exit code }" ;;
    "Pre-rejoin configuration restored; the original pre-join backup was preserved") printf 'Конфигурация до повторного присоединения восстановлена; исходная резервная копия сохранена' ;;
    "Existing domain configuration is incomplete"*) printf 'Существующая доменная конфигурация неполна или не соответствует сохранённому домену' ;;
    "Failed to create the recovery rejoin operation backup") printf 'Не удалось создать резервную копию операции повторного присоединения' ;;
    "Failed to determine the computer object state in LDAP") printf 'Не удалось определить состояние объекта компьютера в LDAP' ;;
    "Existing join state has no pre-join backup"*) printf 'В существующем состоянии нет исходной резервной копии; локальная операция запрещена' ;;
    "Existing join state contains an invalid pre-join backup reference."*) printf 'Существующее состояние содержит некорректную ссылку на исходную резервную копию: %s' "${text#Existing join state contains an invalid pre-join backup reference. }" ;;
    "NOT ACTIVE: "*) printf 'НЕ АКТИВЕН: %s' "${text#NOT ACTIVE: }" ;;
    "Converting CRLF to LF: "*) printf 'Преобразование CRLF в LF: %s' "${text#Converting CRLF to LF: }" ;;
    "Failed to retrieve TLS certificate from "*) printf 'Не удалось получить TLS-сертификат от %s' "${text#Failed to retrieve TLS certificate from }" ;;
    "Server certificate does not cover IP address "*) printf 'Сертификат сервера не содержит IP-адрес %s' "${text#Server certificate does not cover IP address }" ;;
    "Server certificate does not cover DNS name "*) printf 'Сертификат сервера не содержит DNS-имя %s' "${text#Server certificate does not cover DNS name }" ;;
    "Unsupported system CA trust store") printf 'Неподдерживаемое системное хранилище сертификатов' ;;
    "TLS verification failed"*) printf 'Проверка TLS завершилась ошибкой%s' "${text#TLS verification failed}" ;;
    "Changed MultiDirectory certificate was not accepted") printf 'Изменённый сертификат MultiDirectory не был принят' ;;
    "Active join backup is missing or corrupted") printf 'Активная резервная копия присоединения отсутствует или повреждена' ;;
    "Ignoring invalid "*) printf 'Некорректное сохранённое значение проигнорировано: %s' "${text#Ignoring invalid }" ;;
    "No valid join state values found in "*) printf 'В файле состояния не найдено корректных значений: %s' "${text#No valid join state values found in }" ;;
    *) printf 'Внутренняя операция; подробности записаны в журнал' ;;
  esac
}

select_ui_language() {
  local choice

  while true; do
    printf '\n========================================\n'
    printf ' %s\n' "$(tr_text language.title)"
    printf '========================================\n'
    printf '1) %s\n' "$(tr_text language.ru)"
    printf '2) %s\n' "$(tr_text language.en)"
    printf 'Select / Выберите [1]: '
    read_clean_input choice || choice=""
    choice="${choice:-1}"

    case "$choice" in
      1|ru|RU) MD_UI_LANG="ru"; export MD_UI_LANG; return 0 ;;
      2|en|EN) MD_UI_LANG="en"; export MD_UI_LANG; return 0 ;;
      *) printf '[WARN] Select 1 or 2 / Выберите 1 или 2.\n' ;;
    esac
  done
}
