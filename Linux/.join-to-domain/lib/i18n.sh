tr_text() {
  local key="$1"

  case "${MD_UI_LANG:-en}:${key}" in
    ru:language.title) printf 'Выберите язык / Select language' ;;
    ru:language.ru) printf 'Русский' ;;
    ru:language.en) printf 'English' ;;
    ru:menu.title) printf 'Присоединение к домену' ;;
    ru:menu.install) printf 'Установить необходимые пакеты' ;;
    ru:menu.join) printf 'Настроить присоединение к домену' ;;
    ru:menu.rejoin) printf 'Повторно присоединить к домену' ;;
    ru:menu.leave) printf 'Выйти из домена' ;;
    ru:menu.renew_certificate) printf 'Обновить сертификат' ;;
    ru:menu.reboot) printf 'Перезагрузить компьютер' ;;
    ru:menu.exit) printf 'Выход' ;;
    ru:prompt.select) printf 'Выберите пункт' ;;
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
    *:menu.join) printf 'Configure domain join' ;;
    *:menu.rejoin) printf 'Rejoin domain' ;;
    *:menu.leave) printf 'Leave domain' ;;
    *:menu.renew_certificate) printf 'Renew certificate' ;;
    *:menu.reboot) printf 'Reboot PC' ;;
    *:menu.exit) printf 'Exit' ;;
    *:prompt.select) printf 'Select an option' ;;
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
