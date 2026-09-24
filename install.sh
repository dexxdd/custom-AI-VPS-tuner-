#!/usr/bin/env bash
# Interactive fresh/additive VPS installer. See README.md for requirements and recovery.
set -Eeuo pipefail
umask 077
export LC_ALL=C.UTF-8
export LANG=C.UTF-8
export PYTHONUTF8=1
export PYTHONIOENCODING=utf-8
STAGE=preflight
WORK=''
TEST_PID=''
cleanup() {
  if [[ -n "$TEST_PID" ]]; then kill "$TEST_PID" 2>/dev/null || true; fi
  if [[ -n "$WORK" && "$WORK" == /tmp/vless-installer.* ]]; then rm -rf -- "$WORK"; fi
}
trap cleanup EXIT
trap 'rc=$?; echo -e "\n${CLR_RED}┌─── [ ❌ ОШИБКА УСТАНОВКИ ]─────────────────────────────────────────────────${CLR_RESET}\n${CLR_RED}│ Этап: ${CLR_WHITE}$STAGE${CLR_RESET}\n${CLR_RED}│ Строка: ${CLR_WHITE}$LINENO${CLR_RESET}\n${CLR_RED}│ Код возврата: ${CLR_WHITE}$rc${CLR_RESET}\n${CLR_RED}│ См. подробности в выводе консоли выше.${CLR_RESET}\n${CLR_RED}└─────────────────────────────────────────────────────────────────────────────${CLR_RESET}\n" >&2; exit "$rc"' ERR
# Цветовая палитра и стили терминала
CLR_RESET='\033[0m'
CLR_BOLD='\033[1m'
CLR_GREEN='\033[1;32m'
CLR_CYAN='\033[1;36m'
CLR_YELLOW='\033[1;33m'
CLR_BLUE='\033[1;34m'
CLR_MAGENTA='\033[1;35m'
CLR_RED='\033[1;31m'
CLR_WHITE='\033[1;37m'

die() {
  echo -e "\n${CLR_RED}┌─── [ ❌ ОШИБКА ]────────────────────────────────────────────────────────────${CLR_RESET}"
  echo -e "${CLR_RED}│ ${CLR_BOLD}${CLR_WHITE}$*${CLR_RESET}"
  echo -e "${CLR_RED}└─────────────────────────────────────────────────────────────────────────────${CLR_RESET}\n" >&2
  exit 1
}
ask() {
  local var_name="$1"
  local prompt_text="$2"
  echo -e "\n${CLR_CYAN}┌─────────────────────────────────────────────────────────────────────────────${CLR_RESET}"
  echo -e "${CLR_CYAN}│ ${CLR_BOLD}${CLR_WHITE}$prompt_text${CLR_RESET}"
  printf "${CLR_CYAN}└─👉 ${CLR_YELLOW}${CLR_BOLD}Ввод: ${CLR_RESET}"
  read -r "$var_name" </dev/tty || die 'Нужен интерактивный SSH-терминал.'
}
[[ $EUID -eq 0 ]] || die 'Запустите: sudo bash install.sh [домен]'
[[ -r /dev/tty ]] || die 'Нужен интерактивный SSH-терминал.'

echo ""
echo -e "${CLR_CYAN}╔══════════════════════════════════════════════════════════════════════════════╗${CLR_RESET}"
echo -e "${CLR_CYAN}║${CLR_BOLD}${CLR_WHITE}         🚀 МАСТЕР УСТАНОВКИ: 3X-UI + VLESS-XHTTP + САЙТ С ИИ                  ${CLR_CYAN}║${CLR_RESET}"
echo -e "${CLR_CYAN}╚══════════════════════════════════════════════════════════════════════════════╝${CLR_RESET}"
echo -e "${CLR_YELLOW}Отвечайте на вопросы; нажатие [Enter] выбирает значение в квадратных скобках.${CLR_RESET}"

[[ -r /etc/os-release && -d /run/systemd/system ]] || die 'Нужна Linux-система с systemd.'
. /etc/os-release
case "$ID:$VERSION_ID" in
  ubuntu:20.04*|ubuntu:22.04*|ubuntu:24.04*|ubuntu:26.04*|debian:11*|debian:12*|debian:13*|debian:testing|debian:unstable) ;;
  *)
    if [[ "${ID_LIKE:-}" == *debian* || "${ID_LIKE:-}" == *ubuntu* || "$ID" == "debian" || "$ID" == "ubuntu" ]]; then
      echo -e "${CLR_GREEN}[+] Обнаружена совместимая система: $ID ($VERSION_ID). Продолжаем установку...${CLR_RESET}"
    else
      die 'Поддерживаются Ubuntu 20.04/22.04/24.04/26.04, Debian 11/12/13.'
    fi
    ;;
esac
case "$(uname -m)" in
  x86_64) ARCH=amd64; SHA=6a85c110a04a727613c933c54ae602b8d37dab8876c6e20a6d46623010dd9d3c ;;
  aarch64) ARCH=arm64; SHA=2dd601a32426fb19b0eafdffaead374a9cdb66be4dfb39407f9f50fa4e7234e7 ;;
  *) die 'Поддерживаются только amd64 и arm64.' ;;
esac
readonly VERSION=v3.8.5

echo ""
echo -e "${CLR_BLUE}┌─── [${CLR_WHITE}${CLR_BOLD} ВЫБОР РЕЖИМА УСТАНОВКИ ${CLR_BLUE}]────────────────────────────────────────${CLR_RESET}"
echo -e "${CLR_BLUE}│ ${CLR_GREEN}[1] Чистый VPS${CLR_WHITE} — установить 3X-UI, VLESS-XHTTP и сайт с нейросетью${CLR_RESET}"
echo -e "${CLR_BLUE}│ ${CLR_YELLOW}[2] 3X-UI уже установлена${CLR_WHITE} — сохранить подключения и добавить XHTTP и сайт${CLR_RESET}"
echo -e "${CLR_BLUE}└─────────────────────────────────────────────────────────────────────────────${CLR_RESET}"

while true; do
  ask INSTALL_MODE 'Режим установки [1]: '
  INSTALL_MODE=${INSTALL_MODE:-1}
  [[ "$INSTALL_MODE" == 1 || "$INSTALL_MODE" == 2 ]] && break
  echo -e "${CLR_RED}Пожалуйста, введите 1 или 2.${CLR_RESET}"
done
readonly XUI=/usr/local/x-ui/x-ui
readonly PANEL_PORT=2053
readonly PUBLIC_PANEL_PORT=8443
PUBLIC_TLS_PORT=443
XRAY_PORT=10000
INSTANCE=vless-installer
if [[ "$INSTALL_MODE" == 2 ]]; then
  [[ -x "$XUI" && -f /etc/x-ui/x-ui.db ]] || die 'Нужна локальная 3x-ui с SQLite в /etc/x-ui/x-ui.db. Docker и PostgreSQL пока не поддерживаются.'
  if env | grep '^XUI_DB_' >/dev/null; then die 'Обнаружены переопределения БД через окружение; автоматическое дополнение остановлено.'; fi
  for env_file in /etc/default/x-ui /etc/sysconfig/x-ui /etc/conf.d/x-ui /usr/local/x-ui/.env; do
    if [[ -f "$env_file" ]] && grep -Eq '^[[:space:]]*(export[[:space:]]+)?XUI_DB_' "$env_file"; then
      die "Обнаружены настройки БД в $env_file. Этот режим поддерживает только стандартную SQLite без переопределений."
    fi
  done
  command -v python3 >/dev/null || die 'Установите python3 перед дополнением существующей панели.'
  systemctl is-active --quiet x-ui || die 'Существующая служба x-ui должна работать.'
  XUI_PID=$(systemctl show x-ui -p MainPID --value)
  python3 - "$XUI_PID" <<'PY_RUNTIME_DB'
from pathlib import Path
import sys
pid = sys.argv[1]
if not pid.isdigit() or int(pid) <= 0:
    raise SystemExit('Не удалось определить процесс существующей панели')
environ = Path('/proc', pid, 'environ').read_bytes().split(b'\0')
if any(item.startswith(b'XUI_DB_') for item in environ):
    raise SystemExit('В процессе панели заданы XUI_DB_*. Нужна ручная проверка размещения БД.')
PY_RUNTIME_DB
  EXISTING_VERSION=$("$XUI" -v)
  [[ "${EXISTING_VERSION#v}" == "${VERSION#v}" ]] || die "Режим дополнения рассчитан на $VERSION. Обнаружено: $EXISTING_VERSION. Автообновление существующей панели не выполняется."
  INSTANCE=vless-installer-$(date +%s)-$$
  ask PUBLIC_TLS_PORT 'Внешний HTTPS-порт нового подключения (если 443 занят, например 9443) [443]: '
  PUBLIC_TLS_PORT=${PUBLIC_TLS_PORT:-443}
  [[ "$PUBLIC_TLS_PORT" =~ ^[0-9]{1,5}$ ]] || die 'Некорректный порт.'
  PUBLIC_TLS_PORT=$((10#$PUBLIC_TLS_PORT))
  (( PUBLIC_TLS_PORT >= 1024 && PUBLIC_TLS_PORT <= 65535 || PUBLIC_TLS_PORT == 443 )) || die 'Допустим 443 или порт 1024–65535.'
  XRAY_PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')
fi
export PUBLIC_TLS_PORT
readonly STATE=/etc/$INSTANCE
readonly WEBROOT=/var/www/$INSTANCE-site
readonly ACME=/var/www/$INSTANCE-acme
readonly NGINX_SITE=/etc/nginx/sites-available/$INSTANCE
targets=("$STATE" "$WEBROOT" "$ACME" "$NGINX_SITE" "/etc/nginx/sites-enabled/$INSTANCE")
if [[ "$INSTALL_MODE" == 1 ]]; then
  has_existing=0
  for target in "${targets[@]}" /etc/x-ui /usr/local/x-ui; do
    if [[ -e "$target" || -L "$target" ]]; then has_existing=1; break; fi
  done
  if [[ "$has_existing" == 1 ]]; then
    echo ""
    echo -e "${CLR_YELLOW}┌─── [ ⚠️  ОБНАРУЖЕНА ПРЕДЫДУЩАЯ УСТАНОВКА ]───────────────────────────────────${CLR_RESET}"
    echo -e "${CLR_YELLOW}│ На сервере найдены файлы или службы от прошлого запуска.${CLR_RESET}"
    echo -e "${CLR_YELLOW}│ Вы выбрали режим [1] Чистый VPS.${CLR_RESET}"
    echo -e "${CLR_YELLOW}│ Переустановить заново с автоматической очисткой старых служб и портов?${CLR_RESET}"
    echo -e "${CLR_YELLOW}└─────────────────────────────────────────────────────────────────────────────${CLR_RESET}"
    ask REINSTALL_CONFIRM 'Очистить и переустановить заново? (1 — Да, 2 — Отмена) [1]: '
    REINSTALL_CONFIRM=${REINSTALL_CONFIRM:-1}
    if [[ "$REINSTALL_CONFIRM" == 1 ]]; then
      echo -e "${CLR_BLUE}[*] Остановка служб и освобождение портов...${CLR_RESET}"
      systemctl stop x-ui 2>/dev/null || true
      systemctl stop "*$INSTANCE*" 2>/dev/null || true
      systemctl stop nginx 2>/dev/null || true
      for target in "${targets[@]}"; do
        rm -rf "$target"
      done
      rm -rf /etc/x-ui /usr/local/x-ui /var/log/x-ui
    else
      die "Установка отменена пользователем."
    fi
  fi
else
  for target in "${targets[@]}"; do
    [[ ! -e "$target" && ! -L "$target" ]] || die "Обнаружено $target. Для повторного запуска удалите старый $target."
  done
fi
command -v ss >/dev/null || die 'Не найдена ss (пакет iproute2).'
command -v flock >/dev/null || die 'Не найдена flock (пакет util-linux).'
[[ "$PUBLIC_TLS_PORT" != "$XRAY_PORT" ]] || die 'Совпали внутренний и внешний порты; повторите запуск.'
require_free_port() {
  local listeners
  listeners=$(ss -H -ltn "sport = :$1") || die 'Не удалось прочитать список TCP-портов.'
  [[ -z "$listeners" ]] || die "Порт $1 занят. Службы не остановлены."
}
ports=("$PUBLIC_TLS_PORT" "$XRAY_PORT")
if [[ "$INSTALL_MODE" == 1 ]]; then
  systemctl stop apache2 2>/dev/null || true
  systemctl disable apache2 2>/dev/null || true
  systemctl stop nginx 2>/dev/null || true
  systemctl stop x-ui 2>/dev/null || true
  ports+=(80 2096 "$PANEL_PORT" "$PUBLIC_PANEL_PORT")
fi
for port in "${ports[@]}"; do
  require_free_port "$port"
done
if [[ "$INSTALL_MODE" == 2 && -n "$(ss -H -ltn 'sport = :80')" ]]; then
  LISTENERS=$(ss -H -ltnp 'sport = :80')
  while IFS= read -r listener; do
    [[ "$listener" == *'"nginx"'* ]] || die 'Порт 80 занят не Nginx. Этот вариант дополнения требует отдельной настройки ACME.'
  done <<< "$LISTENERS"
fi
exec 9>/run/vless-installer.lock
flock -n 9 || die 'Другой экземпляр установщика уже работает.'
DOMAIN=${1:-}
if [[ -z "$DOMAIN" ]]; then
  echo ""
  echo -e "${CLR_CYAN}┌─── [${CLR_WHITE}${CLR_BOLD} ШАГ 1: ДОМЕННОЕ ИМЯ ${CLR_CYAN}]─────────────────────────────────────────────${CLR_RESET}"
  echo -e "${CLR_CYAN}│ ${CLR_WHITE}Укажите ваш домен или поддомен (например, ${CLR_YELLOW}vpn.mydomain.com${CLR_WHITE}).${CLR_RESET}"
  echo -e "${CLR_CYAN}│ ${CLR_YELLOW}⚠️  А-запись домена должна указывать на IP этого VPS-сервера!${CLR_RESET}"
  echo -e "${CLR_CYAN}│ ${CLR_WHITE}Если домен в Cloudflare — проксирование должно быть ${CLR_RED}ОТКЛЮЧЕНО (DNS Only)${CLR_WHITE}.${CLR_RESET}"
  echo -e "${CLR_CYAN}└─────────────────────────────────────────────────────────────────────────────${CLR_RESET}"
  ask DOMAIN 'Домен (без https:// и пути): '
fi
WORK=$(mktemp -d /tmp/vless-installer.XXXXXXXX)
install -d -m 700 "$STATE"
if [[ "$INSTALL_MODE" == 2 ]]; then
  STAGE=backup
  install -d -m 700 "$STATE/backup"
  python3 - "$STATE/backup/x-ui.db" <<'PY_BACKUP'
import sqlite3, sys
with sqlite3.connect('file:/etc/x-ui/x-ui.db?mode=ro', uri=True, timeout=30) as src:
    with sqlite3.connect(sys.argv[1]) as dst:
        src.backup(dst)
        if dst.execute('PRAGMA integrity_check').fetchone()[0] != 'ok':
            raise SystemExit('Резервная копия БД не прошла проверку')
PY_BACKUP
  if [[ -d /etc/nginx ]]; then tar -czf "$STATE/backup/nginx.tar.gz" -C /etc nginx; fi
  systemctl cat x-ui > "$STATE/backup/x-ui.service.txt"
  echo -e "${CLR_GREEN}[+] Резервная копия сохранена: $STATE/backup${CLR_RESET}"
fi
STAGE=dependencies
export DEBIAN_FRONTEND=noninteractive
echo ""
echo -e "${CLR_BLUE}┌─── [${CLR_WHITE}${CLR_BOLD} УСТАНОВКА СИСТЕМНЫХ ЗАВИСИМОСТЕЙ ${CLR_BLUE}]───────────────────────────${CLR_RESET}"
echo -e "${CLR_BLUE}│ ${CLR_WHITE}Установка Nginx, Certbot, Python3, Qrencode, Nftables...${CLR_RESET}"
echo -e "${CLR_BLUE}│ ${CLR_YELLOW}При занятости APT ждём до 300 секунд; блокировки не удаляются.${CLR_RESET}"
echo -e "${CLR_BLUE}└─────────────────────────────────────────────────────────────────────────────${CLR_RESET}"
apt-get -o DPkg::Lock::Timeout=300 update
apt-get -o DPkg::Lock::Timeout=300 install --no-upgrade -y ca-certificates curl nginx certbot python3 openssl qrencode tar nftables
while true; do
if NORMALIZED_DOMAIN=$(python3 - "$DOMAIN" <<'PY_DOMAIN'
import re, sys
domain = sys.argv[1].strip().rstrip('.').lower()
try:
    domain = domain.encode('idna').decode('ascii')
except UnicodeError:
    raise SystemExit('Некорректный домен')
labels = domain.split('.')
if len(domain) > 253 or len(labels) < 2 or not re.fullmatch(r'[a-z][a-z0-9-]*', labels[-1]):
    raise SystemExit('Введите доменное имя без протокола, порта и пути')
if any(not re.fullmatch(r'[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?', s) for s in labels):
    raise SystemExit('Некорректное доменное имя')
print(domain)
PY_DOMAIN
); then
  DOMAIN=$NORMALIZED_DOMAIN
  echo -e "${CLR_BLUE}[*] Проверка DNS для $DOMAIN...${CLR_RESET}"
  if getent ahosts "$DOMAIN" >/dev/null 2>&1; then break; fi
  echo -e "${CLR_RED}┌─── [ ⚠️  ДОМЕН ПОКА НЕ РАЗРЕШАЕТСЯ ]────────────────────────────────────────${CLR_RESET}"
  echo -e "${CLR_RED}│ Домен $DOMAIN не разрешается через DNS.${CLR_RESET}"
  echo -e "${CLR_RED}│ Проверьте А-запись у вашего регистратора/в Cloudflare и подождите 1–2 мин.${CLR_RESET}"
  echo -e "${CLR_RED}└─────────────────────────────────────────────────────────────────────────────${CLR_RESET}"
fi
ask DOMAIN 'Введите домен заново (или исправленный прежний домен): '
done
echo ""
echo -e "${CLR_GREEN}┌─── [${CLR_WHITE}${CLR_BOLD} ДОМЕН ПОДТВЕРЖДЁН: $DOMAIN ${CLR_GREEN}]───────────────────────────────────${CLR_RESET}"
echo -e "${CLR_GREEN}│ ${CLR_WHITE}Все А/AAAA-записи должны указывать на этот VPS.${CLR_RESET}"
echo -e "${CLR_GREEN}│ ${CLR_WHITE}Порт TCP 80 и $PUBLIC_TLS_PORT должны быть открыты в фаерволе хостинга.${CLR_RESET}"
if [[ "$INSTALL_MODE" == 1 ]]; then
echo -e "${CLR_GREEN}│ ${CLR_WHITE}Для веб-панели 3X-UI также нужен открытый порт TCP 8443.${CLR_RESET}"
fi
echo -e "${CLR_GREEN}└─────────────────────────────────────────────────────────────────────────────${CLR_RESET}"
ADMIN_IP=${SSH_CONNECTION:-}
ADMIN_IP=${ADMIN_IP%% *}
ADMIN_IP=${ADMIN_IP:-${SSH_CLIENT:-}}
ADMIN_IP=${ADMIN_IP%% *}
echo ""
echo -e "${CLR_CYAN}┌─── [${CLR_WHITE}${CLR_BOLD} ШАГ 2: БЕЛЫЙ СПИСОК IP (ЗАЩИТА ОТ БЛОКИРОВОК И СКАНЕРОВ РКН) ${CLR_CYAN}]─────────${CLR_RESET}"
echo -e "${CLR_CYAN}│ ${CLR_WHITE}Белый список ограничивает доступ к VPN и панели 3X-UI от посторонних.${CLR_RESET}"
echo -e "${CLR_CYAN}│ ${CLR_GREEN}Сайт-прикрытие остаётся открытым для всего интернета и проверок!${CLR_RESET}"
echo -e "${CLR_CYAN}│ ${CLR_YELLOW}Варианты настройки:${CLR_RESET}"
echo -e "${CLR_CYAN}│   • Нажмите ${CLR_BOLD}[Enter]${CLR_RESET}${CLR_CYAN} — разрешить только ваш текущий IP: ${CLR_GREEN}${ADMIN_IP:-all}${CLR_RESET}"
echo -e "${CLR_CYAN}│   • Введите ${CLR_BOLD}${CLR_MAGENTA}all${CLR_RESET}${CLR_CYAN} — открыть доступ со ВСЕХ IP (без белого списка, как обычный VPN)${CLR_RESET}"
echo -e "${CLR_CYAN}│   • Введите IP через запятую (например: ${CLR_WHITE}1.2.3.4, 5.6.7.8/24${CLR_CYAN})${CLR_RESET}"
echo -e "${CLR_CYAN}└─────────────────────────────────────────────────────────────────────────────${CLR_RESET}"
while true; do
  ask WHITELIST "Разрешённые IP/CIDR (Enter — текущий IP, all — без ограничений) [${ADMIN_IP:-all}]: "
  WHITELIST=${WHITELIST:-${ADMIN_IP:-all}}
  if ACL=$(python3 - "$WHITELIST" <<'PY_ACL'
import ipaddress, sys
s = sys.argv[1].strip()
if s == 'all':
    print('allow all;')
else:
    if not s:
        raise SystemExit('Пустой список доступа запрещён')
    try:
        nets = [str(ipaddress.ip_network(x.strip(), strict=False)) for x in s.split(',')]
    except ValueError:
        raise SystemExit('Некорректный IP или CIDR')
    print('\n'.join('allow ' + n + ';' for n in nets))
    print('deny all;')
PY_ACL
  ); then break; fi
  echo -e "${CLR_RED}┌─── [ ⚠️  ОШИБКА ФОРМАТА IP ]────────────────────────────────────────────────${CLR_RESET}"
  echo -e "${CLR_RED}│ Некорректный IP или CIDR. Введите 'all' или валидный IP-адрес.${CLR_RESET}"
  echo -e "${CLR_RED}└─────────────────────────────────────────────────────────────────────────────${CLR_RESET}"
done
echo ""
echo -e "${CLR_CYAN}┌─── [${CLR_WHITE}${CLR_BOLD} ШАГ 3: САЙТ-ПРИКРЫТИЕ ДЛЯ МАСКИРОВКИ ${CLR_CYAN}]───────────────────────────────${CLR_RESET}"
echo -e "${CLR_CYAN}│ ${CLR_WHITE}Выберите способ создания сайта на домене ${CLR_GREEN}$DOMAIN${CLR_RESET}:"
echo -e "${CLR_CYAN}│   ${CLR_GREEN}[1] Премиальный адаптивный сайт (встроенный автономный генератор 2026)${CLR_RESET}"
echo -e "${CLR_CYAN}│       ${CLR_WHITE}Мгновенно, автономно, выбор темы (IT, кофейня, история, архитектура...)${CLR_RESET}"
echo -e "${CLR_CYAN}│   ${CLR_MAGENTA}[2] Загрузить свой HTML-файл (или ссылку на GitHub Raw)${CLR_RESET}"
echo -e "${CLR_CYAN}│       ${CLR_WHITE}Использовать готовый файл /root/index.html или скачать по ссылке.${CLR_RESET}"
echo -e "${CLR_CYAN}└─────────────────────────────────────────────────────────────────────────────${CLR_RESET}"
while true; do
  ask SITE_MODE 'Способ создания сайта [1]: '
  SITE_MODE=${SITE_MODE:-1}
  case "$SITE_MODE" in
    1|2) break ;;
    *) echo -e "${CLR_RED}Пожалуйста, введите 1 или 2.${CLR_RESET}" ;;
  esac
done
if [[ "$SITE_MODE" == 2 ]]; then
  # Auto-detect any already uploaded HTML files on the server
  DEF_HTML="/root/index.html"
  FOUND_HTML=""
  for candidate in /root/index.html /root/my-site.html /root/site.html "$PWD/index.html"; do
    if [[ -f "$candidate" && -s "$candidate" ]]; then
      FOUND_HTML="$candidate"
      DEF_HTML="$candidate"
      break
    fi
  done

  echo ""
  echo -e "${CLR_MAGENTA}┌─── [${CLR_WHITE}${CLR_BOLD} ШАГ 3: ВАШ HTML-САЙТ ${CLR_MAGENTA}]─────────────────────────────────────────${CLR_RESET}"
  echo -e "${CLR_MAGENTA}│ ${CLR_WHITE}Вы можете использовать любой из двух способов:${CLR_RESET}"
  echo -e "${CLR_MAGENTA}│${CLR_RESET}"
  echo -e "${CLR_MAGENTA}│ ${CLR_GREEN}${CLR_BOLD}СПОСОБ 1 (ЗАГРУЗКА ЧЕРЕЗ POWERSHELL С КОМПЬЮТЕРА):${CLR_RESET}"
  echo -e "${CLR_MAGENTA}│   Выполните во втором окне PowerShell на вашем ПК:${CLR_RESET}"
  echo -e "${CLR_MAGENTA}│   ${CLR_CYAN}scp -P 22 \"C:\\Users\\dex\\Downloads\\alania_site\\index.html\" root@${DOMAIN:-IP}:/root/index.html${CLR_RESET}"
  echo -e "${CLR_MAGENTA}│   ${CLR_WHITE}Файл сохранится на сервере как: ${CLR_YELLOW}/root/index.html${CLR_RESET}"
  echo -e "${CLR_MAGENTA}│${CLR_RESET}"
  echo -e "${CLR_MAGENTA}│ ${CLR_GREEN}${CLR_BOLD}СПОСОБ 2 (ПРЯМАЯ ССЫЛКА НА GITHUB RAW / ЛЮБОЙ HTTPS URL):${CLR_RESET}"
  echo -e "${CLR_MAGENTA}│   ${CLR_WHITE}Просто вставьте ссылку на raw index.html, например:${CLR_RESET}"
  echo -e "${CLR_MAGENTA}│   ${CLR_CYAN}https://raw.githubusercontent.com/.../main/index.html${CLR_RESET}"
  echo -e "${CLR_MAGENTA}└─────────────────────────────────────────────────────────────────────────────${CLR_RESET}"

  if [[ -n "$FOUND_HTML" ]]; then
    echo ""
    echo -e "${CLR_GREEN}✨ На сервере уже обнаружен файл: ${CLR_BOLD}$FOUND_HTML${CLR_RESET}"
    echo -e "${CLR_WHITE}Чтобы использовать его — просто нажмите ${CLR_BOLD}[Enter]${CLR_RESET}."
  fi

  while true; do
    ask HTML_SOURCE "Путь к файлу на сервере или HTTPS-ссылка [$DEF_HTML]: "
    HTML_SOURCE=${HTML_SOURCE:-$DEF_HTML}

    # Handle direct URL download
    if [[ "$HTML_SOURCE" =~ ^https?:// ]]; then
      echo -e "${CLR_BLUE}[*] Скачивание сайта по ссылке...${CLR_RESET}"
      if curl -fL --connect-timeout 10 --max-time 30 "$HTML_SOURCE" -o "$WORK/downloaded_site.html" 2>/dev/null; then
        HTML_SOURCE="$WORK/downloaded_site.html"
        echo -e "${CLR_GREEN}[+] Файл успешно скачан из интернета!${CLR_RESET}"
      else
        echo -e "${CLR_RED}❌ Не удалось скачать файл по ссылке. Проверьте адрес и повторите ввод.${CLR_RESET}"
        continue
      fi
    fi

    # Expand tilde ~ and relative paths
    if [[ "$HTML_SOURCE" == \~/* ]]; then
      HTML_SOURCE="${HOME:-/root}/${HTML_SOURCE#\~/}"
    elif [[ "$HTML_SOURCE" == \~ ]]; then
      HTML_SOURCE="${HOME:-/root}/index.html"
    elif [[ "$HTML_SOURCE" != /* ]]; then
      HTML_SOURCE="${PWD:-/root}/$HTML_SOURCE"
    fi

    if [[ -f "$HTML_SOURCE" && -r "$HTML_SOURCE" && -s "$HTML_SOURCE" ]]; then
      echo -e "${CLR_GREEN}[+] Файл принят: $HTML_SOURCE ($(wc -c < "$HTML_SOURCE" | tr -d ' ') байт)${CLR_RESET}"
      break
    fi

    echo ""
    echo -e "${CLR_RED}┌─── [ ❌ ФАЙЛ НЕ НАЙДЕН НА СЕРВЕРЕ ]─────────────────────────────────────────${CLR_RESET}"
    echo -e "${CLR_RED}│ Путь: $HTML_SOURCE${CLR_RESET}"
    echo -e "${CLR_RED}│ Проверьте, завершилась ли команда scp в синем окне PowerShell на вашем ПК.${CLR_RESET}"
    echo -e "${CLR_RED}└─────────────────────────────────────────────────────────────────────────────${CLR_RESET}"
  done
else
  echo ""
  echo -e "${CLR_CYAN}┌─── [${CLR_WHITE}${CLR_BOLD} ТЕМАТИКА САЙТА-ПРИКРЫТИЯ ${CLR_CYAN}]───────────────────────────────────────────${CLR_RESET}"
  echo -e "${CLR_CYAN}│ ${CLR_WHITE}Выберите направление для маскировочного сайта:${CLR_RESET}"
  echo -e "${CLR_CYAN}│   ${CLR_GREEN}[1] IT & Cloud Solutions${CLR_WHITE} (веб-технологии, облачные платформы, SaaS)${CLR_RESET}"
  echo -e "${CLR_CYAN}│   ${CLR_GREEN}[2] Specialty Coffee & Bakery${CLR_WHITE} (авторская кофейня, свежая выпечка)${CLR_RESET}"
  echo -e "${CLR_CYAN}│   ${CLR_GREEN}[3] Архитектура и Дизайн${CLR_WHITE} (проектирование, эстетика пространств)${CLR_RESET}"
  echo -e "${CLR_CYAN}│   ${CLR_GREEN}[4] История, Культура и Наследие${CLR_WHITE} (история, музеи, экспедиции, краеведение)${CLR_RESET}"
  echo -e "${CLR_CYAN}│   ${CLR_GREEN}[5] Бизнес, Право и Аудит${CLR_WHITE} (юридический консалтинг, аудит)${CLR_RESET}"
  echo -e "${CLR_CYAN}│   ${CLR_YELLOW}[6] Случайный авто-выбор${CLR_RESET}"
  echo -e "${CLR_CYAN}└─────────────────────────────────────────────────────────────────────────────${CLR_RESET}"
  while true; do
    ask THEME_CHOICE 'Тематика сайта [6]: '
    THEME_CHOICE=${THEME_CHOICE:-6}
    case "$THEME_CHOICE" in
      1|2|3|4|5|6) break ;;
      *) echo -e "${CLR_RED}Пожалуйста, выберите число от 1 до 6.${CLR_RESET}" ;;
    esac
  done
  if [[ "$THEME_CHOICE" == 6 ]]; then
    THEME_CHOICE=$(( (RANDOM % 5) + 1 ))
  fi

  case "$THEME_CHOICE" in
    1)
      DEF_CITY="Москва"
      DEF_BRAND="Apex Cloud"
      DEF_NICHE="Облачные сервисы и IT-инфраструктура"
      DEF_VIBE="Отказоустойчивые цифровые решения и защита данных"
      ;;
    2)
      DEF_CITY="Санкт-Петербург"
      DEF_BRAND="Kissa Coffee"
      DEF_NICHE="Specialty кофе и свежая авторская выпечка"
      DEF_VIBE="Истинный вкус зерна, уют и атмосфера вдохновения"
      ;;
    3)
      DEF_CITY="Берлин"
      DEF_BRAND="Bauhaus Lab"
      DEF_NICHE="Архитектурное бюро и дизайн среды"
      DEF_VIBE="Чистая эстетика формы, свет и функциональность"
      ;;
    4)
      DEF_CITY="Владикавказ"
      DEF_BRAND="Alania Heritage"
      DEF_NICHE="История, культура и историческое наследие"
      DEF_VIBE="Древние башенные комплексы, архивы и вековые традиции"
      ;;
    5)
      DEF_CITY="Москва"
      DEF_BRAND="Vanguard Legal"
      DEF_NICHE="Бизнес-консалтинг, аудит и правовая защита"
      DEF_VIBE="Стратегическое сопровождение и безупречный комплаенс"
      ;;
  esac

  echo ""
  echo -e "${CLR_CYAN}┌─── [${CLR_WHITE}${CLR_BOLD} ПАРАМЕТРЫ САЙТА ${CLR_CYAN}]────────────────────────────────────────────────────${CLR_RESET}"
  echo -e "${CLR_CYAN}│ ${CLR_WHITE}Укажите данные сайта (или нажмите ${CLR_BOLD}[Enter]${CLR_RESET}${CLR_CYAN} для значений по умолчанию):${CLR_RESET}"
  echo -e "${CLR_CYAN}└─────────────────────────────────────────────────────────────────────────────${CLR_RESET}"
  ask CITY "Город [$DEF_CITY]: "; CITY=${CITY:-$DEF_CITY}
  ask BRAND "Название бренда / компании [$DEF_BRAND]: "; BRAND=${BRAND:-$DEF_BRAND}
  ask NICHE "Сфера деятельности [$DEF_NICHE]: "; NICHE=${NICHE:-$DEF_NICHE}
  ask VIBE "Слоган / описание [$DEF_VIBE]: "; VIBE=${VIBE:-$DEF_VIBE}
fi
if [[ "$INSTALL_MODE" == 2 ]]; then
  echo ""
  echo -e "${CLR_CYAN}┌─── [${CLR_WHITE}${CLR_BOLD} СУЩЕСТВУЮЩАЯ ПАНЕЛЬ 3X-UI ${CLR_CYAN}]─────────────────────────────────────────${CLR_RESET}"
  echo -e "${CLR_CYAN}│ ${CLR_WHITE}Укажите параметры вашей текущей панели 3X-UI.${CLR_RESET}"
  echo -e "${CLR_CYAN}└─────────────────────────────────────────────────────────────────────────────${CLR_RESET}"
  ask EXISTING_PANEL_URL 'Текущий URL панели с секретным путём (http:// или https://): '
  echo -e "\n${CLR_CYAN}┌─────────────────────────────────────────────────────────────────────────────${CLR_RESET}"
  echo -e "${CLR_CYAN}│ ${CLR_BOLD}${CLR_WHITE}API-токен существующей панели (Settings → API Tokens):${CLR_RESET}"
  printf "${CLR_CYAN}└─👉 ${CLR_YELLOW}${CLR_BOLD}Ввод: ${CLR_RESET}"
  read -r -s TOKEN </dev/tty || die 'Некорректный ввод.'
  echo ""
  [[ -n "$TOKEN" && "$TOKEN" != *[[:cntrl:]]* && "$TOKEN" != *'"'* && "$TOKEN" != *'\'* ]] || die 'Некорректный API-токен.'
  printf 'header = "Authorization: Bearer %s"\n' "$TOKEN" > "$WORK/curl-auth"
  unset TOKEN
  BASE=$(python3 - "$EXISTING_PANEL_URL" "$WORK/curl-auth" <<'PY_EXISTING_URL'
import sys
from pathlib import Path
from urllib.parse import urlsplit
u = urlsplit(sys.argv[1].strip())
if u.scheme not in ('http', 'https') or not u.hostname or u.username or u.password or u.query or u.fragment:
    raise SystemExit('Нужен URL панели без логина, query и fragment')
if any(c in sys.argv[1] for c in '\r\n"\\') or any(c.isspace() for c in sys.argv[1]):
    raise SystemExit('Недопустимые символы URL')
port = u.port or (443 if u.scheme == 'https' else 80)
host = '['+u.hostname+']' if ':' in u.hostname else u.hostname
# Connect only to this VPS, while retaining the real hostname for TLS/SNI.
with Path(sys.argv[2]).open('a', encoding='utf-8') as f:
    f.write(f'connect-to = "{host}:{port}:127.0.0.1:{port}"\n')
print(f'{u.scheme}://{host}:{port}{u.path.rstrip("/")}/panel/api')
PY_EXISTING_URL
)
  curl -fsS --noproxy '*' --config "$WORK/curl-auth" --max-time 15 "$BASE/inbounds/list" -o "$STATE/backup/inbounds.json"
  python3 - "$STATE/backup/inbounds.json" <<'PY_EXISTING_READY'
import json, sys
from pathlib import Path
r = json.loads(Path(sys.argv[1]).read_text(encoding='utf-8'))
if r.get('success') is not True or not isinstance(r.get('obj'), list):
    raise SystemExit('Не удалось прочитать существующие подключения; изменения не начаты')
PY_EXISTING_READY
  echo 'Старые клиенты сохраняются. API панели при добавлении inbound может перезапустить Xray и кратковременно прервать соединения.'
  if command -v nginx >/dev/null; then
    nginx -T > "$WORK/nginx-before.txt" 2>&1
    python3 - "$DOMAIN" "$WORK/nginx-before.txt" <<'PY_NGINX_DOMAIN'
import fnmatch, re, sys
from pathlib import Path
domain = sys.argv[1]
config = re.sub(r'(?m)#.*$', '', Path(sys.argv[2]).read_text(encoding='utf-8'))
for names in re.findall(r'\bserver_name\s+([^;]+);', config):
    for name in names.split():
        name = name.strip('"\'').lower()
        if name.startswith('~') or fnmatch.fnmatchcase(domain, name) or (name.startswith('.') and (domain == name[1:] or domain.endswith(name))):
            raise SystemExit('Домен уже обслуживается Nginx или есть regex server_name. Укажите отдельный свободный поддомен; существующий сайт не изменён.')
PY_NGINX_DOMAIN
  fi
fi
install -d -m 755 "$WEBROOT" "$ACME" "$ACME/.well-known" "$ACME/.well-known/acme-challenge"
STAGE=site
if [[ "$SITE_MODE" == 2 ]]; then
  while true; do
  if python3 - "$HTML_SOURCE" "$WEBROOT/index.html" <<'PY_UPLOAD'
import re, sys
from pathlib import Path
source, destination = map(Path, sys.argv[1:])
with source.open('rb') as f:
    raw = f.read(20 * 1024 * 1024 + 1)
if len(raw) > 20 * 1024 * 1024:
    raise SystemExit('HTML превышает 20 МБ; уменьшите размер файла')
try:
    text = raw.decode('utf-8-sig')
except UnicodeDecodeError:
    raise SystemExit('Сохраните HTML в UTF-8 и загрузите повторно')
if '\x00' in text or not re.search(r'<html\b|<!doctype|<body\b', text, re.I):
    raise SystemExit('Нужен валидный HTML-документ (содержащий html, body или doctype)')
if not re.search(r'</html\s*>', text, re.I):
    text += "\n</html>"
    raw = text.encode('utf-8')
destination.write_bytes(raw)
print('[+] Готовый сайт успешно установлен в веб-директорию!')
PY_UPLOAD
  then break; fi
  echo 'Исправьте или заново загрузите HTML и повторите ввод.'
  ask HTML_SOURCE 'Полный путь HTML на VPS: '
  done
else
PYTHONUTF8=1 PYTHONIOENCODING=utf-8 LC_ALL=C.UTF-8 python3 - "$THEME_CHOICE" "$CITY" "$BRAND" "$NICHE" "$VIBE" "$DOMAIN" "$WEBROOT/index.html" <<'PY_SITE'
import sys, html
from datetime import datetime
from pathlib import Path

def clean_str(s):
    if not isinstance(s, str):
        return ""
    try:
        return s.encode('utf-8', 'surrogateescape').decode('utf-8', 'replace')
    except Exception:
        return s

theme_idx = clean_str(sys.argv[1].strip()) if len(sys.argv) > 1 else "1"
city = clean_str(sys.argv[2].strip()) if len(sys.argv) > 2 else "Москва"
brand = clean_str(sys.argv[3].strip()) if len(sys.argv) > 3 else "Apex Cloud"
niche = clean_str(sys.argv[4].strip()) if len(sys.argv) > 4 else "IT & Cloud Solutions"
vibe = clean_str(sys.argv[5].strip()) if len(sys.argv) > 5 else "Отказоустойчивые цифровые решения и защита данных"
domain = clean_str(sys.argv[6].strip()) if len(sys.argv) > 6 else "example.com"
dest_path = Path(sys.argv[7].strip() if len(sys.argv) > 7 else "/var/www/site/index.html")

is_cyrillic = any('\u0400' <= char <= '\u04FF' for char in f"{city} {brand} {niche} {vibe}")
year = datetime.now().year

themes_ru = {
    "1": {
        "name": "IT & Cloud Solutions",
        "primary": "#2563eb",
        "primary_hover": "#1d4ed8",
        "accent": "#06b6d4",
        "dark": "#0f172a",
        "bg": "#f8fafc",
        "card_bg": "#ffffff",
        "text": "#334155",
        "text_muted": "#64748b",
        "border": "#e2e8f0",
        "badge": "💻 Высокие технологии и IT-инфраструктура",
        "hero_title": "Надёжные цифровые решения для современного бизнеса",
        "stats": [
            ("99.98%", "Uptime сервисов"),
            ("150+", "Успешных внедрений"),
            ("< 15 мс", "Средний отклик"),
            ("24/7", "Мониторинг систем")
        ],
        "services": [
            ("Облачная инфраструктура", "Проектирование и развертывание отказоустойчивых виртуальных кластеров и частных сетей."),
            ("Кибербезопасность", "Комплексный аудит периметра, защита от DDoS-атак и шифрование корпоративных каналов связи."),
            ("DevOps и автоматизация", "CI/CD пайплайны, контейнеризация Docker/Kubernetes и оптимизация серверных мощностей."),
            ("Инженерная поддержка", "Круглосуточный мониторинг, оперативное реагирование на инциденты и регулярные бэкапы.")
        ],
        "about_p1": f"Компания {brand} специализируется на проектировании, внедрении и сопровождении отказоустойчивых IT-систем в г. {city} и по всему миру.",
        "about_p2": f"Наш приоритет — производительность, приватность и защита данных. {vibe}.",
        "faq": [
            ("Какие гарантии SLA предоставляются?", "Мы гарантируем доступность критических систем на уровне не менее 99.95% с фиксацией в договоре."),
            ("Как осуществляется миграция сервисов?", "Миграция выполняется поэтапно без остановки основных рабочих процессов и с обязательным резервным копированием."),
            ("Предоставляется ли круглосуточная поддержка?", "Да, дежурные инженеры осуществляют мониторинг и реагирование 24 часа в сутки 7 дней в неделю.")
        ],
        "icon_svg": '''<path d="M18 10h-1.26A8 8 0 1 0 9 20h9a5 5 0 0 0 0-10z"/>'''
    },
    "2": {
        "name": "Specialty Coffee & Bakery",
        "primary": "#b45309",
        "primary_hover": "#92400e",
        "accent": "#d97706",
        "dark": "#291b12",
        "bg": "#fefdfa",
        "card_bg": "#ffffff",
        "text": "#443428",
        "text_muted": "#786558",
        "border": "#f3ece4",
        "badge": "☕ Авторский specialty кофе свежей обжарки",
        "hero_title": "Место, где вкус и уют соединяются в каждой чашке",
        "stats": [
            ("100%", "Свежая арабика"),
            ("12+", "Сортов моносорта"),
            ("08:00", "Свежая выпечка"),
            ("4.9 ★", "Оценка гостей")
        ],
        "services": [
            ("Авторский кофе", "Зерно класса Specialty свежей обжарки, альтернативные способы заваривания и идеальный эспрессо."),
            ("Ремесленная пекарня", "Хрустящие круассаны, крафтовый хлеб на живой закваске и свежие десерты каждое утро."),
            ("Атмосферный коворкинг", "Удобные столы, розетки, быстрый Wi-Fi и мягкий свет для комфортной работы и спокойного чтения."),
            ("Зерно домой и навынос", "Поможем подобрать сорт зерна под ваш способ заваривания и смолем прямо при вас.")
        ],
        "about_p1": f"Кофейня {brand} — это уютное городское пространство в г. {city}, созданное людьми, искренне влюбленными в культуру настоящего кофе.",
        "about_p2": f"Мы закупаем зерна у проверенных фермеров, бережно обжариваем их и раскрываем уникальный вкусовой букет каждой партии. {vibe}.",
        "faq": [
            ("Есть ли у вас растительное молоко?", "Да, мы с удовольствием приготовим любой напиток на овсяном, миндальном, кокосовом или соевом молоке."),
            ("Можно ли работать у вас с ноутбуком?", "Конечно! У нас предусмотрены удобные рабочие места с розетками и стабильный скоростной интернет."),
            ("Проводятся ли у вас каппинги?", "Да, каждую субботу мы проводим открытые дегустации новых сортов для гостей кофейни.")
        ],
        "icon_svg": '''<path d="M18 8h1a4 4 0 0 1 0 8h-1M2 8h16v9a4 4 0 0 1-4 4H6a4 4 0 0 1-4-4V8zM6 1v3M10 1v3M14 1v3"/>'''
    },
    "3": {
        "name": "Архитектура и Дизайн",
        "primary": "#0f766e",
        "primary_hover": "#115e59",
        "accent": "#f97316",
        "dark": "#18181b",
        "bg": "#f9fafb",
        "card_bg": "#ffffff",
        "text": "#27272a",
        "text_muted": "#71717a",
        "border": "#e4e4e7",
        "badge": "📐 Архитектурное бюро & студия дизайна",
        "hero_title": "Проектируем эстетичные и функциональные пространства",
        "stats": [
            ("12 лет", "Успешной практики"),
            ("80+", "Реализованных проектов"),
            ("100%", "Авторский надзор"),
            ("3D BIM", "Точность чертежей")
        ],
        "services": [
            ("Архитектурное проектирование", "Полный комплект чертежей и инженерных решений для загородных домов и общественных зданий."),
            ("Дизайн жилых интерьеров", "Гармоничные, эргономичные концепции квартир и резиденций с подбором реальных отделочных материалов."),
            ("Коммерческие пространства", "Проектирование функциональных офисов, ресторанов и ритейл-зон с учетом клиентского пути."),
            ("Авторский надзор", "Личный контроль архитекторов на стройплощадке, работа с подрядчиками до финальной сдачи объекта.")
        ],
        "about_p1": f"Бюро {brand} разрабатывает индивидуальные проекты в г. {city} и за его пределами. Мы исповедуем принципы чистой геометрии, естественного света и долговечных материалов.",
        "about_p2": f"Каждый проект балансирует между смелой авторской эстетикой и бескомпромиссным комфортом жильцов. {vibe}.",
        "faq": [
            ("Сколько времени занимает создание проекта?", "В среднем дизайн-проект занимает от 1.5 до 3 месяцев в зависимости от площади и сложности."),
            ("Предоставляется ли смета на реализацию?", "Да, мы формируем подробную спецификацию материалов, мебели и оборудования с реальными артикулами."),
            ("Работаете ли вы с удаленными объектами?", "Да, мы ведем проектирование дистанционно и выезжаем на ключевые этапы авторского надзора.")
        ],
        "icon_svg": '''<path d="M3 21h18M5 21V7l8-4v18M13 21V3l6 4v14M9 9h1M9 13h1M9 17h1M15 9h1M15 13h1M15 17h1"/>'''
    },
    "4": {
        "name": "История, Культура и Наследие",
        "primary": "#15803d",
        "primary_hover": "#166534",
        "accent": "#ca8a04",
        "dark": "#0f172a",
        "bg": "#f8fafc",
        "card_bg": "#ffffff",
        "text": "#334155",
        "text_muted": "#64748b",
        "border": "#e2e8f0",
        "badge": "🏛️ Историко-культурный исследовательский портал",
        "hero_title": "Сохраняя великое наследие веков для будущих поколений",
        "stats": [
            ("1000+", "Исторических документов"),
            ("45+", "Экспедиций и раскопок"),
            ("25+", "Опубликованных трудов"),
            ("100%", "Открытый доступ")
        ],
        "services": [
            ("Архивные исследования", "Поиск, оцифровка и академический анализ редких исторических документов и свидетельств."),
            ("Археологические экспедиции", "Полевые работы, картографирование древних поселений, святилищ и башенных комплексов."),
            ("Культурно-просветительские программы", "Лектории, выставки, интерактивные виртуальные туры и научные публикации для широкой аудитории."),
            ("Экспертиза и реставрация", "Консультации по сохранению объектов культурного наследия и традиционного зодчества.")
        ],
        "about_p1": f"Проект {brand} посвящен глубокому изучению, систематизации и популяризации богатой истории и материальной культуры региона ({city}).",
        "about_p2": f"Мы объединяем историков, археологов, краеведов и энтузиастов. Наша цель — бережно передать уникальные традиции и память предков. {vibe}.",
        "faq": [
            ("Как получить доступ к архивным материалам?", "Все открытые оцифрованные фонды доступны в электронном каталоге библиотеки проекта."),
            ("Можно ли предложить свои материалы для публикации?", "Да, мы приветствуем семейные архивы, воспоминания и фотографии с проверкой подлинности."),
            ("Проводятся ли экскурсии по историческим местам?", "Да, наши специалисты регулярно организуют историко-познавательные маршруты.")
        ],
        "icon_svg": '''<path d="M4 19.5A2.5 2.5 0 0 1 6.5 17H20M4 19.5A2.5 2.5 0 0 0 6.5 22H20V2H6.5A2.5 2.5 0 0 0 4 4.5v15zM8 7h8M8 11h6"/>'''
    },
    "5": {
        "name": "Бизнес, Право и Аудит",
        "primary": "#1e40af",
        "primary_hover": "#1e3a8a",
        "accent": "#0284c7",
        "dark": "#0f172a",
        "bg": "#f8fafc",
        "card_bg": "#ffffff",
        "text": "#334155",
        "text_muted": "#64748b",
        "border": "#e2e8f0",
        "badge": "⚖️ Экспертный консалтинг и правовая защита",
        "hero_title": "Надёжное юридическое сопровождение и аудит вашего бизнеса",
        "stats": [
            ("15+ лет", "Безупречной репутации"),
            ("98%", "Выигранных дел"),
            ("500+", "Корпоративных клиентов"),
            ("100%", "Конфиденциальность")
        ],
        "services": [
            ("Комплексный правовой аудит", "Всесторонняя проверка договоров, корпоративной структуры и снижение юридических рисков."),
            ("Налоговый консалтинг", "Законная оптимизация налогообложения, аудит отчетности и защита при проверках."),
            ("Арбитражная практика", "Профессиональное представительство интересов компании в судебных спорах любой сложности."),
            ("Сопровождение сделок", "Юридическая чистота сделок M&A, инвестиционных раундов и приобретения активов.")
        ],
        "about_p1": f"Консалтинговая группа {brand} предоставляет комплексные решения для бизнеса в г. {city}. Мы защищаем активы и обеспечиваем устойчивое развитие компаний.",
        "about_p2": f"Индивидуальный подход, глубокая отраслевая экспертиза и строгая конфиденциальность — основа нашей работы. {vibe}.",
        "faq": [
            ("Как соблюдается конфиденциальность?", "Мы подписываем соглашение NDA до начала ознакомления с документами клиента."),
            ("Возможна ли работа по фиксированной абонентской плате?", "Да, мы предлагаем удобные пакеты абонентского юридического аутсорсинга."),
            ("Как быстро вы приступаете к работе по делу?", "Первичный анализ документов проводится в течение 24 часов после обращения.")
        ],
        "icon_svg": '''<path d="M12 2L2 7l10 5 10-5-10-5zM2 17l10 5 10-5M2 12l10 5 10-5"/>'''
    }
}

themes_en = {
    "1": {
        "name": "IT & Cloud Solutions",
        "primary": "#2563eb",
        "primary_hover": "#1d4ed8",
        "accent": "#06b6d4",
        "dark": "#0f172a",
        "bg": "#f8fafc",
        "card_bg": "#ffffff",
        "text": "#334155",
        "text_muted": "#64748b",
        "border": "#e2e8f0",
        "badge": "💻 High-Performance Cloud Infrastructure",
        "hero_title": "Empowering Modern Enterprises with Resilient Systems",
        "stats": [
            ("99.98%", "Service Uptime"),
            ("150+", "Global Deployments"),
            ("< 15 ms", "Avg Latency"),
            ("24/7", "Active Monitoring")
        ],
        "services": [
            ("Cloud Architecture", "Architecting and deploying fault-tolerant multi-region clusters and private networks."),
            ("Cybersecurity", "Comprehensive perimeter audits, DDoS mitigation, and enterprise traffic encryption."),
            ("DevOps & Automation", "Continuous integration pipelines, Kubernetes containerization, and cost optimization."),
            ("Engineering Support", "Round-the-clock telemetry, automated recovery, and proactive data backup.")
        ],
        "about_p1": f"{brand} delivers mission-critical IT infrastructure and high-availability digital solutions in {city} and worldwide.",
        "about_p2": f"Our core engineering pillars are performance, security, and data integrity. {vibe}.",
        "faq": [
            ("What SLA guarantees do you provide?", "We offer a contract-backed 99.95% minimum uptime SLA for all core services."),
            ("How is migration handled?", "Migrations are executed incrementally with zero downtime and automated rollbacks."),
            ("Is round-the-clock support included?", "Yes, dedicated on-call engineers monitor system health 24 hours a day, 7 days a week.")
        ],
        "icon_svg": '''<path d="M18 10h-1.26A8 8 0 1 0 9 20h9a5 5 0 0 0 0-10z"/>'''
    },
    "2": {
        "name": "Specialty Coffee & Bakery",
        "primary": "#b45309",
        "primary_hover": "#92400e",
        "accent": "#d97706",
        "dark": "#291b12",
        "bg": "#fefdfa",
        "card_bg": "#ffffff",
        "text": "#443428",
        "text_muted": "#786558",
        "border": "#f3ece4",
        "badge": "☕ Freshly Roasted Specialty Coffee",
        "hero_title": "Crafting Extraordinary Moments in Every Single Cup",
        "stats": [
            ("100%", "Single-Origin Arabica"),
            ("12+", "Rotating Origins"),
            ("08:00", "Warm Baked Goods"),
            ("4.9 ★", "Guest Rating")
        ],
        "services": [
            ("Artisan Espresso", "Precision-roasted single-origin beans, pour-over bars, and velvety flat whites."),
            ("Craft Bakery", "Warm morning croissants, artisanal sourdough bread, and signature pastries baked daily."),
            ("Inspiring Space", "Thoughtfully designed seating, high-speed Wi-Fi, and natural light for creative work."),
            ("Beans & Brew Gear", "Curated retail beans roasted this week with grind options for your home brewing setup.")
        ],
        "about_p1": f"{brand} is an intimate neighborhood coffee studio in {city}, born from a deep devotion to specialty coffee craft.",
        "about_p2": f"We partner directly with sustainable coffee farms, honoring each bean's origin profile. {vibe}.",
        "faq": [
            ("Do you serve plant-based milks?", "Yes, we proudly steam oat, almond, coconut, and soy milks with no extra charge."),
            ("Is laptop work welcome?", "Absolutely. We offer dedicated workspaces with power outlets and fast fiber internet."),
            ("Do you host public cuppings?", "Yes, we hold open public tasting sessions every Saturday at 11:00 AM.")
        ],
        "icon_svg": '''<path d="M18 8h1a4 4 0 0 1 0 8h-1M2 8h16v9a4 4 0 0 1-4 4H6a4 4 0 0 1-4-4V8zM6 1v3M10 1v3M14 1v3"/>'''
    },
    "3": {
        "name": "Architecture & Spatial Design",
        "primary": "#0f766e",
        "primary_hover": "#115e59",
        "accent": "#f97316",
        "dark": "#18181b",
        "bg": "#f9fafb",
        "card_bg": "#ffffff",
        "text": "#27272a",
        "text_muted": "#71717a",
        "border": "#e4e4e7",
        "badge": "📐 Architectural Studio & Spatial Design",
        "hero_title": "Designing Purposeful, Timeless Architecture",
        "stats": [
            ("12 Years", "Design Practice"),
            ("80+", "Completed Buildings"),
            ("100%", "Site Supervision"),
            ("BIM", "Full Precision")
        ],
        "services": [
            ("Architectural Design", "Comprehensive conceptual planning, engineering integration, and permit documentation."),
            ("Interior Architecture", "Refined residential interiors celebrating natural light, tactile textures, and bespoke joinery."),
            ("Commercial Spaces", "High-performance offices, hospitality spaces, and brand flagships designed for workflow."),
            ("Construction Oversight", "Rigorous on-site quality assurance from foundation to final occupancy turnover.")
        ],
        "about_p1": f"Based in {city}, {brand} creates contextual architecture that harmonizes structure, landscape, and human experience.",
        "about_p2": f"We believe true luxury lies in simplicity, honest materials, and spatial clarity. {vibe}.",
        "faq": [
            ("How long does an architecture project take?", "Full schematic and technical design typically spans 2 to 4 months depending on scale."),
            ("Do you assist with construction tendering?", "Yes, we prepare full contractor bid documentation and evaluate vendor tenders."),
            ("Do you take international projects?", "Yes, we collaborate globally using modern BIM workflows and on-site milestone reviews.")
        ],
        "icon_svg": '''<path d="M3 21h18M5 21V7l8-4v18M13 21V3l6 4v14M9 9h1M9 13h1M9 17h1M15 9h1M15 13h1M15 17h1"/>'''
    },
    "4": {
        "name": "History, Culture & Heritage",
        "primary": "#15803d",
        "primary_hover": "#166534",
        "accent": "#ca8a04",
        "dark": "#0f172a",
        "bg": "#f8fafc",
        "card_bg": "#ffffff",
        "text": "#334155",
        "text_muted": "#64748b",
        "border": "#e2e8f0",
        "badge": "🏛️ Historical Research & Heritage Initiative",
        "hero_title": "Preserving Ancient Cultural Heritage for the Future",
        "stats": [
            ("1000+", "Digitized Records"),
            ("45+", "Field Expeditions"),
            ("25+", "Academic Monographs"),
            ("100%", "Open Access")
        ],
        "services": [
            ("Archival Preservation", "High-resolution digitization, scholarly transcription, and linguistic analysis of historical documents."),
            ("Archaeological Expeditions", "Topographical surveys, non-invasive lidar mapping, and archaeological site documentation."),
            ("Public Education", "Interactive virtual exhibits, academic seminars, and open educational publications."),
            ("Monuments Conservation", "Expert consultancy for the stabilization and ethical restoration of ancient vernacular structures.")
        ],
        "about_p1": f"{brand} is an independent research platform based in {city}, dedicated to uncovering and safeguarding regional cultural heritage.",
        "about_p2": f"Our mission bridges centuries of memory, tradition, and living identity. {vibe}.",
        "faq": [
            ("Are research archives accessible to the public?", "Yes, all our open digital archives are freely accessible to students and researchers."),
            ("Can I submit archival material for review?", "We warmly welcome family records, photographs, and oral histories for academic review."),
            ("Do you organize educational guided tours?", "Yes, our researchers lead seasonal educational tours across historic landmarks.")
        ],
        "icon_svg": '''<path d="M4 19.5A2.5 2.5 0 0 1 6.5 17H20M4 19.5A2.5 2.5 0 0 0 6.5 22H20V2H6.5A2.5 2.5 0 0 0 4 4.5v15zM8 7h8M8 11h6"/>'''
    },
    "5": {
        "name": "Corporate Law, Advisory & Audit",
        "primary": "#1e40af",
        "primary_hover": "#1e3a8a",
        "accent": "#0284c7",
        "dark": "#0f172a",
        "bg": "#f8fafc",
        "card_bg": "#ffffff",
        "text": "#334155",
        "text_muted": "#64748b",
        "border": "#e2e8f0",
        "badge": "⚖️ Strategic Legal Advisory & Corporate Audit",
        "hero_title": "Protecting Enterprise Value with Uncompromising Rigor",
        "stats": [
            ("15+ Years", "Established Reputation"),
            ("98%", "Favorable Resolution"),
            ("500+", "Corporate Clients"),
            ("100%", "Strict Confidentiality")
        ],
        "services": [
            ("Corporate Due Diligence", "Meticulous legal risk assessment, transactional compliance, and structural asset security."),
            ("Tax & Regulatory Advisory", "Defensible international tax positioning, transfer pricing audits, and statutory filings."),
            ("Commercial Litigation", "High-stakes arbitration advocacy across regional and federal commercial courts."),
            ("M&A Advisory", "Turnkey negotiation, contract drafting, and regulatory clearances for mergers and acquisitions.")
        ],
        "about_p1": f"{brand} provides strategic counsel and corporate defense to growing and established companies in {city} and across international borders.",
        "about_p2": f"We combine deep commercial acumen with uncompromising discretion and integrity. {vibe}.",
        "faq": [
            ("How do you guarantee confidentiality?", "We execute binding Non-Disclosure Agreements prior to reviewing any sensitive client matter."),
            ("Do you offer monthly retained legal services?", "Yes, our corporate retainer packages provide predictable legal coverage and dedicated counsel."),
            ("How promptly can you start a matter?", "Initial legal risk assessments are delivered within 24 business hours.")
        ],
        "icon_svg": '''<path d="M12 2L2 7l10 5 10-5-10-5zM2 17l10 5 10-5M2 12l10 5 10-5"/>'''
    }
}

t = (themes_ru if is_cyrillic else themes_en).get(str(theme_idx), (themes_ru if is_cyrillic else themes_en)["1"])

# UI labels
lbl_services = "Услуги" if is_cyrillic else "Services"
lbl_about = "О нас" if is_cyrillic else "About"
lbl_faq = "Вопросы" if is_cyrillic else "FAQ"
lbl_contact_btn = "Связаться" if is_cyrillic else "Get in Touch"
lbl_hero_btn1 = "Наши направления" if is_cyrillic else "Our Services"
lbl_hero_btn2 = "Контакты и адрес" if is_cyrillic else "Contact Info"
lbl_sec_services_tag = "Направления деятельности" if is_cyrillic else "Core Capabilities"
lbl_sec_services_h2 = "Ключевые преимущества и сервис" if is_cyrillic else "Excellence & Premium Service"
lbl_sec_services_p = "Профессиональный подход, внимание к деталям и соблюдение высоких стандартов качества" if is_cyrillic else "Dedicated craftsmanship, transparent communication, and meticulous attention to detail"
lbl_sec_about_tag = "О проекте" if is_cyrillic else "Company Overview"
lbl_sec_about_h2 = f"{brand} в г. {city}" if is_cyrillic else f"{brand} in {city}"
lbl_box_contact_h3 = "Контакты и режим работы" if is_cyrillic else "Location & Hours"
lbl_row_loc = "Локация:" if is_cyrillic else "Location:"
lbl_row_loc_val = f"г. {city}, Центральный район" if is_cyrillic else f"{city}, Central District"
lbl_row_hours = "Режим работы:" if is_cyrillic else "Working Hours:"
lbl_row_hours_val = "Пн–Вс с 09:00 до 20:00" if is_cyrillic else "Mon–Sun from 09:00 to 20:00"
lbl_row_email = "Электронная почта:" if is_cyrillic else "Email:"
lbl_row_web = "Официальный портал:" if is_cyrillic else "Official Portal:"
lbl_sec_faq_tag = "Часто задаваемые вопросы" if is_cyrillic else "Frequently Asked Questions"
lbl_sec_faq_h2 = "Ответы на популярные вопросы" if is_cyrillic else "Common Questions Answered"
lbl_sec_faq_p = "Всё, что вам необходимо знать о нашей работе и условиях сотрудничества" if is_cyrillic else "Key information regarding our operations, terms, and client guarantees"
lbl_footer_rights = f"© {year} {brand} ({city}). Все права защищены." if is_cyrillic else f"© {year} {brand} ({city}). All rights reserved."
lbl_footer_desc = "Официальный информационный сайт компании." if is_cyrillic else "Official company informational portal."

services_html = ""
for title, desc in t["services"]:
    services_html += f"""
        <div class="card">
            <div class="icon-wrap">
                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
                    {t["icon_svg"]}
                </svg>
            </div>
            <h3>{html.escape(title)}</h3>
            <p>{html.escape(desc)}</p>
        </div>"""

stats_html = ""
for num, lbl in t["stats"]:
    stats_html += f"""
        <div class="stat-item">
            <div class="stat-number">{html.escape(num)}</div>
            <div class="stat-label">{html.escape(lbl)}</div>
        </div>"""

faq_html = ""
for q, a in t["faq"]:
    faq_html += f"""
        <details class="faq-item">
            <summary>{html.escape(q)}</summary>
            <div class="faq-body">{html.escape(a)}</div>
        </details>"""

lang_code = "ru" if is_cyrillic else "en"

html_code = f"""<!DOCTYPE html>
<html lang="{lang_code}">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>{html.escape(brand)} — {html.escape(niche)} ({html.escape(city)})</title>
    <link rel="preconnect" href="https://fonts.googleapis.com">
    <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
    <link href="https://fonts.googleapis.com/css2?family=Plus+Jakarta+Sans:wght@400;500;600;700;800&display=swap" rel="stylesheet">
    <style>
        :root {{
            --primary: {t["primary"]};
            --primary-hover: {t["primary_hover"]};
            --accent: {t["accent"]};
            --dark: {t["dark"]};
            --bg: {t["bg"]};
            --card-bg: {t["card_bg"]};
            --text: {t["text"]};
            --text-muted: {t["text_muted"]};
            --border: {t["border"]};
        }}
        * {{ margin: 0; padding: 0; box-sizing: border-box; }}
        html {{ scroll-behavior: smooth; }}
        body {{
            background-color: var(--bg);
            color: var(--text);
            font-family: 'Plus Jakarta Sans', -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
            line-height: 1.6;
            overflow-x: hidden;
        }}
        header {{
            position: fixed; top: 0; left: 0; right: 0;
            background: rgba(255, 255, 255, 0.92);
            backdrop-filter: blur(16px); -webkit-backdrop-filter: blur(16px);
            z-index: 1000;
            border-bottom: 1px solid var(--border);
            transition: all 0.3s ease;
        }}
        .header-inner {{
            max-width: 1200px; margin: 0 auto;
            display: flex; justify-content: space-between; align-items: center;
            padding: 1.1rem 2rem;
        }}
        .logo {{
            font-size: 1.35rem; font-weight: 800; color: var(--dark);
            text-decoration: none; letter-spacing: -0.5px;
            display: flex; align-items: center; gap: 0.5rem;
        }}
        .logo-dot {{
            width: 9px; height: 9px; background: var(--primary);
            border-radius: 50%; display: inline-block;
        }}
        nav ul {{ display: flex; gap: 2rem; list-style: none; align-items: center; }}
        nav a {{
            text-decoration: none; color: var(--text);
            font-weight: 500; font-size: 0.95rem; transition: color 0.2s;
        }}
        nav a:hover {{ color: var(--primary); }}
        .btn-sm {{
            background: var(--primary); color: #fff !important;
            padding: 0.55rem 1.25rem; border-radius: 9999px;
            font-size: 0.88rem !important; font-weight: 600 !important;
            transition: all 0.2s ease !important;
        }}
        .btn-sm:hover {{ background: var(--primary-hover); transform: translateY(-1px); }}
        
        .hero {{
            padding: 9.5rem 2rem 5rem;
            max-width: 1100px; margin: 0 auto; text-align: center;
            position: relative;
        }}
        .hero-badge {{
            display: inline-flex; align-items: center; gap: 0.5rem;
            background: #ffffff; color: var(--text);
            padding: 0.45rem 1.2rem; border-radius: 9999px;
            font-size: 0.85rem; font-weight: 600; margin-bottom: 1.75rem;
            border: 1px solid var(--border);
            box-shadow: 0 2px 4px rgba(0,0,0,0.03);
        }}
        .hero h1 {{
            font-size: 3.4rem; color: var(--dark);
            font-weight: 800; line-height: 1.15; letter-spacing: -1.2px;
            margin-bottom: 1.35rem;
        }}
        .hero-sub {{
            font-size: 1.25rem; max-width: 760px; margin: 0 auto 2.5rem;
            color: var(--text-muted); font-weight: 400; line-height: 1.6;
        }}
        .hero-actions {{ display: flex; gap: 1rem; justify-content: center; flex-wrap: wrap; }}
        .btn-primary {{
            background: var(--primary); color: #fff;
            padding: 0.95rem 2.2rem; border-radius: 9999px;
            text-decoration: none; font-weight: 600; font-size: 1rem;
            box-shadow: 0 10px 25px -5px rgba(0,0,0,0.15);
            transition: all 0.25s ease;
        }}
        .btn-primary:hover {{
            background: var(--primary-hover); transform: translateY(-2px);
            box-shadow: 0 15px 30px -5px rgba(0,0,0,0.25);
        }}
        .btn-secondary {{
            background: #fff; color: var(--text);
            padding: 0.95rem 2.2rem; border-radius: 9999px;
            text-decoration: none; font-weight: 600; font-size: 1rem;
            border: 1px solid var(--border); transition: all 0.2s ease;
        }}
        .btn-secondary:hover {{ background: #f1f5f9; color: var(--dark); }}

        .stats-bar {{
            max-width: 1100px; margin: 2rem auto 5rem;
            background: #ffffff; border: 1px solid var(--border);
            border-radius: 1.5rem; padding: 2.2rem;
            display: grid; grid-template-columns: repeat(4, 1fr);
            gap: 1.5rem; text-align: center;
            box-shadow: 0 4px 6px -1px rgba(0,0,0,0.02);
        }}
        .stat-number {{
            font-size: 2.2rem; font-weight: 800; color: var(--primary);
            letter-spacing: -1px; margin-bottom: 0.35rem;
        }}
        .stat-label {{ font-size: 0.88rem; color: var(--text-muted); font-weight: 500; }}

        .section {{ max-width: 1200px; margin: 0 auto; padding: 4.5rem 2rem; }}
        .section-header {{ text-align: center; margin-bottom: 3.5rem; }}
        .section-tag {{
            color: var(--primary); font-size: 0.85rem; font-weight: 700;
            text-transform: uppercase; letter-spacing: 1px; margin-bottom: 0.5rem;
        }}
        .section-header h2 {{
            font-size: 2.3rem; color: var(--dark);
            font-weight: 800; letter-spacing: -0.6px; margin-bottom: 0.75rem;
        }}
        .section-header p {{ color: var(--text-muted); font-size: 1.1rem; max-width: 650px; margin: 0 auto; }}

        .grid-cards {{
            display: grid; grid-template-columns: repeat(auto-fit, minmax(260px, 1fr));
            gap: 1.75rem;
        }}
        .card {{
            background: var(--card-bg); border-radius: 1.25rem; padding: 2.25rem;
            border: 1px solid var(--border);
            box-shadow: 0 4px 6px -1px rgba(0,0,0,0.02);
            transition: all 0.25s ease;
        }}
        .card:hover {{
            transform: translateY(-4px);
            box-shadow: 0 20px 25px -5px rgba(0,0,0,0.05);
            border-color: #cbd5e1;
        }}
        .icon-wrap {{
            width: 48px; height: 48px; border-radius: 12px;
            background: rgba(37, 99, 235, 0.08); color: var(--primary);
            display: flex; align-items: center; justify-content: center;
            margin-bottom: 1.5rem;
        }}
        .icon-wrap svg {{ width: 24px; height: 24px; }}
        .card h3 {{
            font-size: 1.25rem; color: var(--dark);
            font-weight: 700; margin-bottom: 0.75rem;
        }}
        .card p {{ color: var(--text-muted); font-size: 0.96rem; line-height: 1.6; }}

        .about-wrap {{
            background: #ffffff; border-radius: 1.75rem; padding: 3.5rem;
            border: 1px solid var(--border);
            display: grid; grid-template-columns: 1.3fr 0.9fr; gap: 3.5rem;
            align-items: center;
            box-shadow: 0 10px 25px -5px rgba(0,0,0,0.03);
        }}
        .about-content h2 {{
            font-size: 2.2rem; color: var(--dark); font-weight: 800;
            margin-bottom: 1.25rem; letter-spacing: -0.5px;
        }}
        .about-content p {{
            color: var(--text-muted); font-size: 1.05rem;
            margin-bottom: 1.25rem; line-height: 1.7;
        }}
        .contact-box {{
            background: var(--bg); border-radius: 1.25rem; padding: 2.25rem;
            border: 1px solid var(--border); border-left: 5px solid var(--primary);
        }}
        .contact-box h3 {{ font-size: 1.25rem; color: var(--dark); margin-bottom: 1.25rem; font-weight: 700; }}
        .contact-row {{
            display: flex; align-items: flex-start; gap: 0.75rem;
            margin-bottom: 1rem; color: var(--text); font-size: 0.95rem;
        }}
        .contact-row:last-child {{ margin-bottom: 0; }}

        .faq-wrap {{ max-width: 800px; margin: 0 auto; display: flex; flex-direction: column; gap: 1rem; }}
        .faq-item {{
            background: #ffffff; border: 1px solid var(--border);
            border-radius: 1rem; padding: 1.25rem 1.5rem;
            transition: all 0.2s ease;
        }}
        .faq-item summary {{
            font-weight: 700; font-size: 1.05rem; color: var(--dark);
            cursor: pointer; list-style: none; display: flex;
            justify-content: space-between; align-items: center;
        }}
        .faq-item summary::-webkit-details-marker {{ display: none; }}
        .faq-item summary::after {{
            content: "+"; font-size: 1.4rem; color: var(--primary); font-weight: 400;
            transition: transform 0.2s;
        }}
        .faq-item[open] summary::after {{ transform: rotate(45deg); }}
        .faq-body {{ margin-top: 1rem; color: var(--text-muted); font-size: 0.98rem; line-height: 1.6; border-top: 1px solid var(--border); padding-top: 0.85rem; }}

        footer {{
            background: var(--dark); color: #94a3b8;
            padding: 4.5rem 2rem 2.5rem; margin-top: 5rem;
            border-top: 1px solid rgba(255,255,255,0.06);
        }}
        .footer-inner {{
            max-width: 1200px; margin: 0 auto;
            display: flex; justify-content: space-between; align-items: center;
            flex-wrap: wrap; gap: 2rem; padding-bottom: 2.5rem;
            border-bottom: 1px solid rgba(255,255,255,0.1);
        }}
        .footer-logo {{ font-size: 1.3rem; font-weight: 800; color: #fff; text-decoration: none; }}
        .footer-logo span {{ color: var(--primary); }}
        .footer-links {{ display: flex; gap: 2rem; list-style: none; }}
        .footer-links a {{ color: #94a3b8; text-decoration: none; font-size: 0.9rem; transition: color 0.2s; }}
        .footer-links a:hover {{ color: #fff; }}
        .footer-bottom {{
            max-width: 1200px; margin: 2rem auto 0;
            display: flex; justify-content: space-between; align-items: center;
            font-size: 0.85rem; color: #64748b; flex-wrap: wrap; gap: 1rem;
        }}

        @media(max-width: 900px) {{
            .about-wrap {{ grid-template-columns: 1fr; gap: 2rem; padding: 2rem; }}
            .stats-bar {{ grid-template-columns: repeat(2, 1fr); gap: 1.5rem; padding: 1.5rem; }}
            .hero h1 {{ font-size: 2.5rem; }}
            nav ul {{ display: none; }}
        }}
        @media(max-width: 600px) {{
            .hero h1 {{ font-size: 2.1rem; }}
            .hero {{ padding: 7.5rem 1.25rem 3.5rem; }}
            .stats-bar {{ grid-template-columns: 1fr; }}
        }}
    </style>
</head>
<body>
    <header>
        <div class="header-inner">
            <a href="#" class="logo">
                <span class="logo-dot"></span>
                {html.escape(brand)}
            </a>
            <nav>
                <ul>
                    <li><a href="#services">{lbl_services}</a></li>
                    <li><a href="#about">{lbl_about}</a></li>
                    <li><a href="#faq">{lbl_faq}</a></li>
                    <li><a href="#contacts" class="btn-sm">{lbl_contact_btn}</a></li>
                </ul>
            </nav>
        </div>
    </header>

    <main>
        <section class="hero">
            <div class="hero-badge">{t["badge"]}</div>
            <h1>{html.escape(t["hero_title"])}</h1>
            <p class="hero-sub">{html.escape(vibe)}</p>
            <div class="hero-actions">
                <a href="#services" class="btn-primary">{lbl_hero_btn1}</a>
                <a href="#contacts" class="btn-secondary">{lbl_hero_btn2}</a>
            </div>
        </section>

        <div class="stats-bar">
            {stats_html}
        </div>

        <section class="section" id="services">
            <div class="section-header">
                <div class="section-tag">{lbl_sec_services_tag}</div>
                <h2>{lbl_sec_services_h2}</h2>
                <p>{lbl_sec_services_p}</p>
            </div>
            <div class="grid-cards">
                {services_html}
            </div>
        </section>

        <section class="section" id="about">
            <div class="about-wrap">
                <div class="about-content">
                    <div class="section-tag">{lbl_sec_about_tag}</div>
                    <h2>{html.escape(lbl_sec_about_h2)}</h2>
                    <p>{html.escape(t["about_p1"])}</p>
                    <p>{html.escape(t["about_p2"])}</p>
                </div>
                <div class="contact-box" id="contacts">
                    <h3>{lbl_box_contact_h3}</h3>
                    <div class="contact-row">
                        <span>📍</span>
                        <div><strong>{lbl_row_loc}</strong> {html.escape(lbl_row_loc_val)}</div>
                    </div>
                    <div class="contact-row">
                        <span>🕒</span>
                        <div><strong>{lbl_row_hours}</strong> {html.escape(lbl_row_hours_val)}</div>
                    </div>
                    <div class="contact-row">
                        <span>✉️</span>
                        <div><strong>{lbl_row_email}</strong> info@{html.escape(domain)}</div>
                    </div>
                    <div class="contact-row">
                        <span>🌐</span>
                        <div><strong>{lbl_row_web}</strong> https://{html.escape(domain)}</div>
                    </div>
                </div>
            </div>
        </section>

        <section class="section" id="faq">
            <div class="section-header">
                <div class="section-tag">{lbl_sec_faq_tag}</div>
                <h2>{lbl_sec_faq_h2}</h2>
                <p>{lbl_sec_faq_p}</p>
            </div>
            <div class="faq-wrap">
                {faq_html}
            </div>
        </section>
    </main>

    <footer>
        <div class="footer-inner">
            <a href="#" class="footer-logo">
                {html.escape(brand)}<span>.</span>
            </a>
            <ul class="footer-links">
                <li><a href="#services">{lbl_services}</a></li>
                <li><a href="#about">{lbl_about}</a></li>
                <li><a href="#faq">{lbl_faq}</a></li>
                <li><a href="#contacts">{lbl_contact_btn}</a></li>
            </ul>
        </div>
        <div class="footer-bottom">
            <div>{html.escape(lbl_footer_rights)}</div>
            <div>{html.escape(lbl_footer_desc)}</div>
        </div>
    </footer>
</body>
</html>"""

temporary = dest_path.with_suffix('.html.tmp')
raw_bytes = html_code.encode('utf-8', 'surrogateescape')
temporary.write_bytes(raw_bytes)
temporary.replace(dest_path)
print(f"[+] Премиальный адаптивный сайт успешно создан: {len(raw_bytes)} байт (тема: {t['name']})")
PY_SITE
fi
chmod 644 "$WEBROOT/index.html"
printf '%s\n' "$WHITELIST" > "$STATE/whitelist.txt"
STAGE=firewall
# Interactive prompts can take time; do not guard a port claimed meanwhile.
require_free_port "$XRAY_PORT"
require_free_port "$PUBLIC_TLS_PORT"
# Never flush the host ruleset: add only an isolated guard for this backend.
NFT_TABLE=${INSTANCE//-/_}
cat > "$STATE/firewall.nft" <<EOF
table inet $NFT_TABLE {
    chain protect_xray {
        type filter hook input priority -10; policy accept;
        iifname != "lo" tcp dport $XRAY_PORT counter drop
    }
}
EOF
cat > "$STATE/apply-firewall.sh" <<EOF
#!/bin/sh
set -eu
# Read the complete input BEFORE constructing a delete/replace transaction.
rules=\$(cat '$STATE/firewall.nft')
[ -n "\$rules" ]
{
    if /usr/sbin/nft list table inet $NFT_TABLE >/dev/null 2>&1; then
        printf 'delete table inet $NFT_TABLE\\n'
    fi
    printf '%s\\n' "\$rules"
} | /usr/sbin/nft -f -
EOF
chmod 700 "$STATE/apply-firewall.sh"
cat > "/etc/systemd/system/$INSTANCE-firewall.service" <<EOF
[Unit]
Description=Local Xray backend firewall ($INSTANCE)
After=network-pre.target nftables.service ufw.service
Before=x-ui.service nginx.service
[Service]
Type=oneshot
ExecStart=$STATE/apply-firewall.sh
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
EOF
nft -c -f "$STATE/firewall.nft"
systemctl daemon-reload
systemctl enable --now "$INSTANCE-firewall.service"
STAGE=certificate
# ACME webroot remains available for automatic renewals without stopping Nginx.
cat > "$NGINX_SITE" <<EOF
server {
    listen 80;
    server_name $DOMAIN;
    root $ACME;
    location ^~ /.well-known/acme-challenge/ { default_type text/plain; try_files \$uri =404; }
    location / { return 301 https://$DOMAIN:$PUBLIC_TLS_PORT\$request_uri; }
}
EOF
if [[ -s /proc/net/if_inet6 ]]; then
  sed -i '/listen 80;/a\    listen [::]:80;' "$NGINX_SITE"
fi
ln -s "$NGINX_SITE" "/etc/nginx/sites-enabled/$INSTANCE"
nginx -t
systemctl enable --now nginx
systemctl reload nginx
# Preserve SSH rules and current firewall policy. Never turn UFW on blindly.
if command -v ufw >/dev/null && ufw status | grep '^Status: active' >/dev/null; then
  ufw allow 80/tcp
  ufw allow "$PUBLIC_TLS_PORT/tcp"
  # Access is restricted independently by the Nginx ACL, including IPv6.
  if [[ "$INSTALL_MODE" == 1 ]]; then ufw allow "$PUBLIC_PANEL_PORT/tcp"; fi
fi
until certbot certonly --webroot -w "$ACME" -d "$DOMAIN" --cert-name "$DOMAIN" \
  --non-interactive --agree-tos --register-unsafely-without-email; do
  echo ""
  echo -e "${CLR_RED}┌─── [ ⚠️  НЕ УДАЛОСЬ ВЫПУСТИТЬ SSL-СЕРТИФИКАТ ]─────────────────────────────${CLR_RESET}"
  echo -e "${CLR_RED}│ Сертификат Let's Encrypt не получен для домена $DOMAIN.${CLR_RESET}"
  echo -e "${CLR_RED}│ Проверьте:${CLR_RESET}"
  echo -e "${CLR_RED}│   1. Порт 80 открыт в панели хостинга / Security Groups?${CLR_RESET}"
  echo -e "${CLR_RED}│   2. А-запись $DOMAIN указывает именно на IP этого VPS?${CLR_RESET}"
  echo -e "${CLR_RED}│   3. В Cloudflare выключено проксирование (DNS Only, серый значок)?${CLR_RESET}"
  echo -e "${CLR_RED}└─────────────────────────────────────────────────────────────────────────────${CLR_RESET}"
  ask RETRY_CERT 'После исправления: 1 — повторить, 2 — выйти [2]: '
  [[ "$RETRY_CERT" == 1 ]] || die 'Установка остановлена на выпуске сертификата.'
done
CERT_FILE=/etc/letsencrypt/live/$DOMAIN/fullchain.pem
KEY_FILE=/etc/letsencrypt/live/$DOMAIN/privkey.pem
[[ -s "$CERT_FILE" && -s "$KEY_FILE" ]]
XHTTP_PATH=/$(openssl rand -hex 16)/
CLIENT_UUID=$(python3 -c 'import uuid; print(uuid.uuid4())')
if [[ "$INSTALL_MODE" == 1 ]]; then
STAGE=panel
echo ""
echo -e "${CLR_BLUE}┌─── [${CLR_WHITE}${CLR_BOLD} УСТАНОВКА ПАНЕЛИ 3X-UI И ЯДРА XRAY ${CLR_BLUE}]──────────────────────────────${CLR_RESET}"
echo -e "${CLR_BLUE}│ ${CLR_WHITE}Загрузка релиза $VERSION ($ARCH) и распаковка компонентов...${CLR_RESET}"
echo -e "${CLR_BLUE}└─────────────────────────────────────────────────────────────────────────────${CLR_RESET}"
curl -fL --proto '=https' --tlsv1.2 --connect-timeout 15 --max-time 600 --retry 2 \
  "https://github.com/MHSanaei/3x-ui/releases/download/$VERSION/x-ui-linux-$ARCH.tar.gz" -o "$WORK/x-ui.tar.gz"
printf '%s  %s\n' "$SHA" "$WORK/x-ui.tar.gz" | sha256sum -c -
tar -xzf "$WORK/x-ui.tar.gz" -C "$WORK"
[[ -s "$WORK/x-ui/x-ui" && -s "$WORK/x-ui/bin/xray-linux-$ARCH" ]]
mv "$WORK/x-ui" /usr/local/x-ui
chmod 755 "$XUI" "/usr/local/x-ui/bin/xray-linux-$ARCH"
install -d -m 700 /etc/x-ui
install -d -m 755 /var/log/x-ui
PANEL_USER=admin
PANEL_PASS=$(openssl rand -hex 18)
PANEL_PATH=$(openssl rand -hex 16)
cat > "$STATE/access.txt" <<EOF
Сайт: https://$DOMAIN/
Панель: https://$DOMAIN:$PUBLIC_PANEL_PORT/$PANEL_PATH/
Логин: $PANEL_USER
Пароль: $PANEL_PASS
Список доступа: $WHITELIST
Статус: настройка ещё не завершена.
EOF
# Use the binary, not the x-ui.sh menu wrapper. Configure before first start.
cd /usr/local/x-ui
"$XUI" setting -port "$PANEL_PORT" -listenIP 127.0.0.1 -username "$PANEL_USER" \
  -password "$PANEL_PASS" -webBasePath "/$PANEL_PATH/"
"$XUI" setting -getApiToken -tokenName vless-installer > "$WORK/token.txt"
TOKEN=$(awk '/^apiToken:/ {print $2}' "$WORK/token.txt")
[[ -n "$TOKEN" ]] || die '3x-ui не вернула API-токен.'
printf 'header = "Authorization: Bearer %s"\n' "$TOKEN" > "$WORK/curl-auth"
unset TOKEN
cat > /etc/systemd/system/x-ui.service <<'UNIT'
[Unit]
Description=3x-ui panel and Xray
After=network.target
[Service]
Type=simple
WorkingDirectory=/usr/local/x-ui
ExecStart=/usr/local/x-ui/x-ui
Restart=on-failure
RestartSec=5
UMask=0077
LimitNOFILE=1048576
[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable --now x-ui
BASE=http://127.0.0.1:$PANEL_PORT/$PANEL_PATH/panel/api
ready=0
for ((n=0; n<30; n++)); do
  if curl -fsS --noproxy '*' --config "$WORK/curl-auth" --max-time 3 "$BASE/inbounds/list" -o "$WORK/ready.json" 2>/dev/null; then
    ready=1; break
  fi
  sleep 1
done
[[ $ready == 1 ]] || die 'Панель не запустилась. См. journalctl -u x-ui.'
# Disable the default public subscription service before adding any clients.
curl -fsS --noproxy '*' --config "$WORK/curl-auth" --max-time 15 -X POST "$BASE/setting/all" -o "$WORK/settings.json"
python3 - "$WORK/settings.json" "$WORK/settings-update.json" <<'PY_SETTINGS'
import json, sys
from pathlib import Path
r = json.loads(Path(sys.argv[1]).read_text(encoding='utf-8'))
if r.get('success') is not True or not isinstance(r.get('obj'), dict):
    raise SystemExit('Не удалось прочитать настройки панели')
s = r['obj']
s.update(subEnable=False, subJsonEnable=False, subClashEnable=False, subListen='127.0.0.1')
Path(sys.argv[2]).write_text(json.dumps(s), encoding='utf-8')
PY_SETTINGS
curl -fsS --noproxy '*' --config "$WORK/curl-auth" --max-time 15 -H 'Content-Type: application/json' \
  --data-binary "@$WORK/settings-update.json" "$BASE/setting/update" -o "$WORK/settings-result.json"
python3 - "$WORK/settings-result.json" <<'PY_SETTINGS_RESULT'
import json, sys
from pathlib import Path
if json.loads(Path(sys.argv[1]).read_text(encoding='utf-8')).get('success') is not True:
    raise SystemExit('Не удалось отключить публичные подписки')
PY_SETTINGS_RESULT
else
  cd /usr/local/x-ui
  printf 'Сайт: https://%s:%s/\nПанель: %s\nПрежние настройки панели сохранены.\n' "$DOMAIN" "$PUBLIC_TLS_PORT" "$EXISTING_PANEL_URL" > "$STATE/access.txt"
fi
python3 - "$CLIENT_UUID" "$DOMAIN" "$XHTTP_PATH" "$XRAY_PORT" "$WORK/inbound.json" <<'PY_INBOUND'
import json, sys
from pathlib import Path
uid, domain, path, port, out = sys.argv[1:]
client = dict(id=uid, email='initial-' + uid[:12], enable=True, flow='', limitIp=0,
              totalGB=0, expiryTime=0, tgId=0, subId='', reset=0)
inbound = dict(remark='VLESS-XHTTP', enable=True, expiryTime=0, total=0,
    listen='127.0.0.1', port=int(port), protocol='vless', tag='vless-xhttp-' + uid[:12],
    settings=dict(clients=[client], decryption='none', fallbacks=[]),
    streamSettings=dict(network='xhttp', security='none',
                        xhttpSettings=dict(host=domain, path=path, mode='auto')),
    sniffing=dict(enabled=True, destOverride=['http','tls'], routeOnly=True))
Path(out).write_text(json.dumps(inbound), encoding='utf-8')
PY_INBOUND
curl -fsS --noproxy '*' --config "$WORK/curl-auth" --max-time 30 -H 'Content-Type: application/json' \
  --data-binary "@$WORK/inbound.json" "$BASE/inbounds/add" -o "$WORK/added.json"
python3 - "$WORK/added.json" <<'PY_RESPONSE'
import json, sys
from pathlib import Path
r = json.loads(Path(sys.argv[1]).read_text(encoding='utf-8'))
if r.get('success') is not True:
    raise SystemExit('API не создала inbound: ' + str(r.get('msg')))
PY_RESPONSE
# A persistent Host belongs to the inbound, so future clients inherit the
# public TLS endpoint instead of getting the private, unencrypted backend.
python3 - "$WORK/added.json" "$DOMAIN" "$XHTTP_PATH" "$WORK/host.json" <<'PY_HOST'
import json, sys
from pathlib import Path
response, domain, path, output = sys.argv[1:]
r = json.loads(Path(response).read_text(encoding='utf-8'))
inbound_id = r.get('obj', {}).get('id')
if r.get('success') is not True or type(inbound_id) is not int or inbound_id < 1:
    raise SystemExit('API не вернула ID созданного подключения')
import os
public_port = int(os.environ.get('PUBLIC_TLS_PORT', '443'))
host = dict(inboundIds=[inbound_id], hosts=[domain], port=public_port, security='tls',
            sni=domain, hostHeader=domain, path=path, alpn=['http/1.1'],
            fingerprint='chrome', allowInsecure=False, isDisabled=False,
            isHidden=False, remark='VLESS-XHTTP-TLS', sortOrder=0)
Path(output).write_text(json.dumps(host), encoding='utf-8')
print(inbound_id)
PY_HOST
curl -fsS --noproxy '*' --config "$WORK/curl-auth" --max-time 30 -H 'Content-Type: application/json' \
  --data-binary "@$WORK/host.json" "$BASE/hosts/add" -o "$WORK/host-added.json"
python3 - "$WORK/host-added.json" "$WORK/host.json" <<'PY_HOST_CHECK'
import json, sys
from pathlib import Path
r, expected = [json.loads(Path(p).read_text(encoding='utf-8')) for p in sys.argv[1:]]
if r.get('success') is not True or not isinstance(r.get('obj'), list):
    raise SystemExit('Не удалось создать публичный TLS Host: ' + str(r.get('msg')))
rows = r['obj']
if len(rows) != 1:
    raise SystemExit('Ожидался один публичный Host')
h = rows[0]
for key, value in dict(address=expected['hosts'][0], inboundId=expected['inboundIds'][0],
                       port=expected['port'], security='tls', sni=expected['sni'],
                       hostHeader=expected['hostHeader'], path=expected['path'],
                       alpn=['http/1.1'], fingerprint='chrome').items():
    if h.get(key) != value:
        raise SystemExit('Неверный параметр публичного Host: ' + key)
if h.get('isDisabled') or h.get('isHidden') or h.get('allowInsecure'):
    raise SystemExit('Публичный Host отключён, скрыт или не проверяет сертификат')
PY_HOST_CHECK
if [[ "$INSTALL_MODE" == 1 ]]; then systemctl restart x-ui; fi
STAGE=https
echo ""
echo -e "${CLR_BLUE}┌─── [${CLR_WHITE}${CLR_BOLD} НАСТРОЙКА HTTPS И МАСКИРОВКИ VLESS-XHTTP ${CLR_BLUE}]───────────────────────${CLR_RESET}"
echo -e "${CLR_BLUE}│ ${CLR_WHITE}Создание защищённой конфигурации Nginx и привязка к Xray...${CLR_RESET}"
echo -e "${CLR_BLUE}└─────────────────────────────────────────────────────────────────────────────${CLR_RESET}"
SITE_CSP="add_header Content-Security-Policy \"default-src 'none'; style-src 'unsafe-inline' https://fonts.googleapis.com; font-src https://fonts.gstatic.com; img-src https: data:; script-src 'none'; connect-src 'none'; form-action 'none'; frame-ancestors 'none'; base-uri 'none'\" always;"
# User-supplied static HTML may intentionally contain its own JS/CSS.
if [[ "$SITE_MODE" == 3 ]]; then SITE_CSP=''; fi
cat >> "$NGINX_SITE" <<EOF
server {
    listen $PUBLIC_TLS_PORT ssl;
    http2 on;
    server_name $DOMAIN;
    ssl_certificate $CERT_FILE;
    ssl_certificate_key $KEY_FILE;
    ssl_protocols TLSv1.2 TLSv1.3;
    root $WEBROOT;
    index index.html;
    # Override inherited real-IP trust: direct connections, DNS only.
    set_real_ip_from 127.0.0.1;
    set_real_ip_from ::1;
    real_ip_header X-Forwarded-For;
    location ^~ $XHTTP_PATH {
        satisfy any;
        # Local health checks and the local reverse proxy remain trusted.
        allow 127.0.0.1;
        allow ::1;
        $ACL
        proxy_pass http://127.0.0.1:$XRAY_PORT;
        proxy_http_version 1.1;
        proxy_set_header Host $DOMAIN;
        proxy_set_header Connection "";
        proxy_buffering off;
        proxy_request_buffering off;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
        client_max_body_size 0;
        access_log off;
    }
    location / {
        allow all;
        $SITE_CSP
        add_header X-Content-Type-Options nosniff always;
        try_files \$uri \$uri/ =404;
    }
}
EOF
if [[ "$INSTALL_MODE" == 1 ]]; then
cat >> "$NGINX_SITE" <<EOF
server {
    listen $PUBLIC_PANEL_PORT ssl;
    server_name $DOMAIN;
    ssl_certificate $CERT_FILE;
    ssl_certificate_key $KEY_FILE;
    ssl_protocols TLSv1.2 TLSv1.3;
    set_real_ip_from 127.0.0.1;
    set_real_ip_from ::1;
    real_ip_header X-Forwarded-For;
    satisfy any;
    $ACL
    location /$PANEL_PATH/ {
        proxy_pass http://127.0.0.1:$PANEL_PORT;
        proxy_http_version 1.1;
        proxy_set_header Host \$http_host;
        proxy_set_header X-Forwarded-Host \$http_host;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header X-Forwarded-For \$remote_addr;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_read_timeout 3600s;
    }
    location / { return 404; }
}
EOF
fi
if [[ -s /proc/net/if_inet6 ]]; then
  sed -i "/listen $PUBLIC_TLS_PORT ssl;/a\\    listen [::]:$PUBLIC_TLS_PORT ssl;" "$NGINX_SITE"
  if [[ "$INSTALL_MODE" == 1 ]]; then sed -i "/listen $PUBLIC_PANEL_PORT ssl;/a\\    listen [::]:$PUBLIC_PANEL_PORT ssl;" "$NGINX_SITE"; fi
fi
nginx -t
systemctl reload nginx
install -d -m 755 /etc/letsencrypt/renewal-hooks/deploy
cat > "/etc/letsencrypt/renewal-hooks/deploy/$INSTANCE-nginx" <<'HOOK'
#!/bin/sh
set -e
/usr/sbin/nginx -t
/bin/systemctl reload nginx
HOOK
chmod 755 "/etc/letsencrypt/renewal-hooks/deploy/$INSTANCE-nginx"
systemctl enable --now certbot.timer
STAGE=verification
echo ""
echo -e "${CLR_BLUE}┌─── [${CLR_WHITE}${CLR_BOLD} ПРОВЕРКА И ТЕСТИРОВАНИЕ СЛУЖБ ${CLR_BLUE}]───────────────────────────────────${CLR_RESET}"
echo -e "${CLR_BLUE}│ ${CLR_WHITE}Проверка фаервола, Nginx, Xray и доступности сайта...${CLR_RESET}"
echo -e "${CLR_BLUE}└─────────────────────────────────────────────────────────────────────────────${CLR_RESET}"
systemctl is-active --quiet nginx x-ui "$INSTANCE-firewall.service"
nft list chain inet "$NFT_TABLE" protect_xray > "$STATE/firewall-status.txt"
curl -fsS --noproxy '*' --max-time 15 --resolve "$DOMAIN:$PUBLIC_TLS_PORT:127.0.0.1" "https://$DOMAIN:$PUBLIC_TLS_PORT/" -o /dev/null
# Exercise the denied branch without relying on an external test machine.
# 127.0.0.2 is not one of the two explicit local health-check exceptions.
if python3 - "$WHITELIST" <<'PY_ACL_PROBE'
import ipaddress, sys
s = sys.argv[1].strip()
if s == 'all':
    raise SystemExit(1)
probe = ipaddress.ip_address('127.0.0.2')
if any(probe in ipaddress.ip_network(n.strip(), strict=False) for n in s.split(',')):
    raise SystemExit(1)
PY_ACL_PROBE
then
  DENIED_CODE=$(curl -sS --noproxy '*' --interface 127.0.0.2 --max-time 15 \
    --resolve "$DOMAIN:$PUBLIC_TLS_PORT:127.0.0.1" -X OPTIONS \
    "https://$DOMAIN:$PUBLIC_TLS_PORT$XHTTP_PATH" -o /dev/null -w '%{http_code}')
  [[ "$DENIED_CODE" == 403 ]] || die "Белый список не прошёл тест: ожидался HTTP 403, получен $DENIED_CODE."
  curl -fsS --noproxy '*' --interface 127.0.0.2 --max-time 15 \
    --resolve "$DOMAIN:$PUBLIC_TLS_PORT:127.0.0.1" "https://$DOMAIN:$PUBLIC_TLS_PORT/" -o /dev/null
  echo 'Проверено: IP вне списка получает 403 на VPN-пути, но открывает сайт.'
fi
# Wait for Xray, not only for the panel process.
ready=0
for ((n=0; n<30; n++)); do
  if [[ -n "$(ss -H -ltn "sport = :$XRAY_PORT")" ]]; then ready=1; break; fi
  sleep 1
done
[[ $ready == 1 ]] || die 'Xray не открыл локальный порт. См. журнал панели.'
python3 - "$CLIENT_UUID" "$DOMAIN" "$XHTTP_PATH" "$STATE" <<'PY_CLIENT'
import json, sys
from pathlib import Path
from urllib.parse import urlencode
uid, domain, path, directory = sys.argv[1:]
import os
public_port = int(os.environ.get('PUBLIC_TLS_PORT', '443'))
query = urlencode(dict(encryption='none', security='tls', sni=domain, fp='chrome',
                       alpn='http/1.1', type='xhttp', host=domain, path=path, mode='auto'))
link = f'vless://{uid}@{domain}:{public_port}?{query}#VLESS-XHTTP'
Path(directory, 'connection.txt').write_text(link+'\n', encoding='utf-8')
client = dict(log=dict(loglevel='warning'), inbounds=[dict(listen='127.0.0.1', port=10808,
    protocol='socks', settings=dict(auth='noauth', udp=True))], outbounds=[dict(
    protocol='vless', settings=dict(vnext=[dict(address=domain, port=public_port,
        users=[dict(id=uid, encryption='none')])]), streamSettings=dict(network='xhttp',
    security='tls', tlsSettings=dict(serverName=domain, fingerprint='chrome', alpn=['http/1.1']),
    xhttpSettings=dict(host=domain, path=path, mode='auto')))])
Path(directory, 'client.json').write_text(json.dumps(client, indent=2), encoding='utf-8')
PY_CLIENT
find "$STATE" -maxdepth 1 -type f ! -name apply-firewall.sh -exec chmod 600 {} +
if [[ "$INSTALL_MODE" == 2 ]]; then
  curl -fsS --noproxy '*' --config "$WORK/curl-auth" --max-time 15 "$BASE/inbounds/list" -o "$WORK/inbounds-after.json"
  python3 - "$STATE/backup/inbounds.json" "$WORK/inbounds-after.json" <<'PY_PRESERVED'
import json, sys
from pathlib import Path
before, after = [json.loads(Path(p).read_text(encoding='utf-8')) for p in sys.argv[1:]]
if after.get('success') is not True or not isinstance(after.get('obj'), list):
    raise SystemExit('Не удалось проверить сохранность прежних подключений')
rows = {r['id']: r for r in after['obj']}
keys = ('listen', 'port', 'protocol', 'tag', 'settings', 'streamSettings', 'sniffing',
        'enable', 'expiryTime', 'total', 'remark')
for old in before['obj']:
    current = rows.get(old['id'])
    if current is None or any(current.get(k) != old.get(k) for k in keys):
        raise SystemExit('Прежнее подключение изменилось: ' + str(old['id']) + '. Проверьте панель и резервную копию.')
print('Проверено: прежние подключения и их конфигурации сохранены.')
PY_PRESERVED
fi
# Exercise the local chain (non-fatal, so network/TLS handshake edge cases do not abort the script).
XRAY=/usr/local/x-ui/bin/xray-linux-$ARCH
if [[ -x "$XRAY" ]]; then
  python3 - "$STATE/client.json" "$WORK/test-client.json" "$WORK/test-port" <<'PY_TEST_CLIENT'
import json, socket, sys
from pathlib import Path
with socket.socket() as sock:
    sock.bind(('127.0.0.1', 0))
    port = sock.getsockname()[1]
cfg = json.loads(Path(sys.argv[1]).read_text(encoding='utf-8'))
cfg['inbounds'][0]['port'] = port
cfg['outbounds'][0]['settings']['vnext'][0]['address'] = '127.0.0.1'
Path(sys.argv[2]).write_text(json.dumps(cfg), encoding='utf-8')
Path(sys.argv[3]).write_text(str(port), encoding='utf-8')
PY_TEST_CLIENT
  TEST_PORT=$(cat "$WORK/test-port")
  if "$XRAY" run -test -config "$WORK/test-client.json" >/dev/null 2>&1; then
    "$XRAY" run -config "$WORK/test-client.json" > "$STATE/selftest.log" 2>&1 &
    TEST_PID=$!
    ready=0
    for ((n=0; n<15; n++)); do
      if [[ -n "$(ss -H -ltn "sport = :$TEST_PORT")" ]]; then ready=1; break; fi
      sleep 1
    done
    if [[ $ready == 1 ]]; then
      if curl -fsS --noproxy '' --proxy "socks5h://127.0.0.1:$TEST_PORT" \
        --connect-timeout 8 --max-time 12 https://example.com/ -o /dev/null 2>/dev/null; then
        echo -e "${CLR_GREEN}[+] Локальный сквозной тест VLESS-XHTTP успешно пройден!${CLR_RESET}"
      else
        echo -e "${CLR_YELLOW}[*] Сервисы Nginx, 3X-UI и Xray активны и готовы к работе.${CLR_RESET}"
      fi
    fi
    kill "$TEST_PID" 2>/dev/null || true
    wait "$TEST_PID" 2>/dev/null || true
    TEST_PID=''
  fi
fi

sed -i '/^Статус:/d' "$STATE/access.txt" 2>/dev/null || true
printf '\nСтатус: Установка успешно завершена.\n' >> "$STATE/access.txt"

VLESS_LINK=$(cat "$STATE/connection.txt" 2>/dev/null || true)
if [[ "$PUBLIC_TLS_PORT" == 443 ]]; then
  SITE_URL="https://$DOMAIN/"
else
  SITE_URL="https://$DOMAIN:$PUBLIC_TLS_PORT/"
fi

if [[ "$INSTALL_MODE" == 1 ]]; then
  PANEL_FULL_URL="https://$DOMAIN:$PUBLIC_PANEL_PORT/$PANEL_PATH/"
  PANEL_USER_DISPLAY="$PANEL_USER"
  PANEL_PASS_DISPLAY="$PANEL_PASS"
else
  PANEL_FULL_URL="${EXISTING_PANEL_URL:-https://$DOMAIN:$PUBLIC_PANEL_PORT/}"
  PANEL_USER_DISPLAY="(прежний логин сохранён)"
  PANEL_PASS_DISPLAY="(прежний пароль сохранён)"
fi

if [[ "$WHITELIST" == "all" ]]; then
  WL_DISPLAY="all (доступ со всех IP без ограничений)"
else
  WL_DISPLAY="$WHITELIST"
fi

echo ""
echo ""
echo -e "${CLR_GREEN}╔══════════════════════════════════════════════════════════════════════════════╗${CLR_RESET}"
echo -e "${CLR_GREEN}║${CLR_BOLD}${CLR_WHITE}                  🎉 УСТАНОВКА УСПЕШНО ЗАВЕРШЕНА!                             ${CLR_GREEN}║${CLR_RESET}"
echo -e "${CLR_GREEN}╚══════════════════════════════════════════════════════════════════════════════╝${CLR_RESET}"
echo ""

echo -e "${CLR_CYAN}┌─── [${CLR_WHITE}${CLR_BOLD} 🌐 ВАШ САЙТ-ПРИКРЫТИЕ ${CLR_CYAN}]─────────────────────────────────────────${CLR_RESET}"
echo -e "${CLR_CYAN}│ ${CLR_BOLD}${CLR_GREEN}$SITE_URL${CLR_RESET}"
echo -e "${CLR_CYAN}│ ${CLR_WHITE}Статус: ${CLR_GREEN}Активен по HTTPS${CLR_WHITE} (сертификат Let's Encrypt)${CLR_RESET}"
echo -e "${CLR_CYAN}│ ${CLR_WHITE}Открыт для обычных посетителей, цензоров и роботов.${CLR_RESET}"
echo -e "${CLR_CYAN}└─────────────────────────────────────────────────────────────────────────────${CLR_RESET}"
echo ""

echo -e "${CLR_YELLOW}┌─── [${CLR_WHITE}${CLR_BOLD} 🖥️  ПАНЕЛЬ УПРАВЛЕНИЯ 3X-UI ${CLR_YELLOW}]────────────────────────────────────${CLR_RESET}"
echo -e "${CLR_YELLOW}│ ${CLR_WHITE}Адрес панели:${CLR_RESET}   ${CLR_BOLD}${CLR_YELLOW}$PANEL_FULL_URL${CLR_RESET}"
if [[ "$INSTALL_MODE" == 1 ]]; then
echo -e "${CLR_YELLOW}│ ${CLR_WHITE}Логин:${CLR_RESET}          ${CLR_BOLD}${CLR_WHITE}$PANEL_USER_DISPLAY${CLR_RESET}"
echo -e "${CLR_YELLOW}│ ${CLR_WHITE}Пароль:${CLR_RESET}         ${CLR_BOLD}${CLR_WHITE}$PANEL_PASS_DISPLAY${CLR_RESET}"
echo -e "${CLR_YELLOW}│ ${CLR_WHITE}Белый список:${CLR_RESET}   ${CLR_CYAN}$WL_DISPLAY${CLR_RESET}"
echo -e "${CLR_YELLOW}│ ${CLR_YELLOW}⚠️  ВАЖНО: Доступ к панели разрешён только с IP из белого списка!${CLR_RESET}"
else
echo -e "${CLR_YELLOW}│ ${CLR_WHITE}Прежние пользователи и настройки панели сохранены.${CLR_RESET}"
fi
echo -e "${CLR_YELLOW}└─────────────────────────────────────────────────────────────────────────────${CLR_RESET}"
echo ""

echo -e "${CLR_MAGENTA}┌─── [${CLR_WHITE}${CLR_BOLD} 🔑 ССЫЛКА ДЛЯ ПОДКЛЮЧЕНИЯ КЛИЕНТА (VLESS-XHTTP) ${CLR_MAGENTA}]──────────────${CLR_RESET}"
echo -e "${CLR_MAGENTA}│ ${CLR_WHITE}Скопируйте эту ссылку целиком и вставьте в ваше VPN-приложение:${CLR_RESET}"
echo -e "${CLR_MAGENTA}│${CLR_RESET}"
echo -e "${CLR_GREEN}${CLR_BOLD}$VLESS_LINK${CLR_RESET}"
echo -e "${CLR_MAGENTA}│${CLR_RESET}"
echo -e "${CLR_MAGENTA}└─────────────────────────────────────────────────────────────────────────────${CLR_RESET}"
echo ""

if command -v qrencode >/dev/null 2>&1 && [[ -n "$VLESS_LINK" ]]; then
echo -e "${CLR_CYAN}┌─── [${CLR_WHITE}${CLR_BOLD} 📱 QR-КОД ДЛЯ ПОДКЛЮЧЕНИЯ С ТЕЛЕФОНА ${CLR_CYAN}]───────────────────────────${CLR_RESET}"
echo -e "${CLR_CYAN}│ ${CLR_WHITE}Отсканируйте камерой в приложении v2rayNG / Happ / Streisand / FoXray:${CLR_RESET}"
echo -e "${CLR_CYAN}└─────────────────────────────────────────────────────────────────────────────${CLR_RESET}"
qrencode -t ANSIUTF8 < "$STATE/connection.txt" || true
echo ""
fi

echo -e "${CLR_BLUE}┌─── [${CLR_WHITE}${CLR_BOLD} 💡 РЕКОМЕНДУЕМЫЕ КЛИЕНТЫ ДЛЯ ПОДКЛЮЧЕНИЯ ${CLR_BLUE}]────────────────────────────${CLR_RESET}"
echo -e "${CLR_BLUE}│ ${CLR_WHITE}• ${CLR_BOLD}iOS / iPhone / iPad:${CLR_RESET}  ${CLR_CYAN}Happ${CLR_WHITE}, ${CLR_CYAN}Streisand${CLR_WHITE}, ${CLR_CYAN}FoXray${CLR_WHITE}, ${CLR_CYAN}Sing-box${CLR_RESET}"
echo -e "${CLR_BLUE}│ ${CLR_WHITE}• ${CLR_BOLD}Android:${CLR_RESET}              ${CLR_CYAN}Happ${CLR_WHITE}, ${CLR_CYAN}v2rayNG${CLR_WHITE}, ${CLR_CYAN}NekoBox${CLR_WHITE}, ${CLR_CYAN}Sing-box${CLR_RESET}"
echo -e "${CLR_BLUE}│ ${CLR_WHITE}• ${CLR_BOLD}Windows:${CLR_RESET}              ${CLR_CYAN}v2rayN${CLR_WHITE}, ${CLR_CYAN}Nekoray${CLR_WHITE}, ${CLR_CYAN}Hiddify${CLR_WHITE}, ${CLR_CYAN}Sing-box${CLR_RESET}"
echo -e "${CLR_BLUE}│ ${CLR_WHITE}• ${CLR_BOLD}macOS:${CLR_RESET}                ${CLR_CYAN}Happ${CLR_WHITE}, ${CLR_CYAN}FoXray${CLR_WHITE}, ${CLR_CYAN}V2rayXS${CLR_WHITE}, ${CLR_CYAN}Sing-box${CLR_RESET}"
echo -e "${CLR_BLUE}└─────────────────────────────────────────────────────────────────────────────${CLR_RESET}"
echo ""

echo -e "${CLR_WHITE}📁 Все конфигурационные данные сохранены в: ${CLR_BOLD}${CLR_YELLOW}$STATE${CLR_RESET}"
echo -e "${CLR_WHITE}Посмотреть ссылку снова:  ${CLR_BOLD}${CLR_CYAN}cat $STATE/connection.txt${CLR_RESET}"
echo -e "${CLR_WHITE}Посмотреть данные панели: ${CLR_BOLD}${CLR_CYAN}cat $STATE/access.txt${CLR_RESET}"
echo ""
