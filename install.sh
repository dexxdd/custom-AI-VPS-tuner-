#!/usr/bin/env bash
# Interactive fresh/additive VPS installer. See README.md for requirements and recovery.
set -Eeuo pipefail
umask 077
export LC_ALL=C.UTF-8
STAGE=preflight
WORK=''
TEST_PID=''
cleanup() {
  if [[ -n "$TEST_PID" ]]; then kill "$TEST_PID" 2>/dev/null || true; fi
  if [[ -n "$WORK" && "$WORK" == /tmp/vless-installer.* ]]; then rm -rf -- "$WORK"; fi
}
trap cleanup EXIT
trap 'rc=$?; printf "\nОшибка на этапе %s, строка %s (код %s). Установка НЕ завершена.\n" "$STAGE" "$LINENO" "$rc" >&2; exit "$rc"' ERR
die() { printf '%s\n' "$*" >&2; exit 1; }
ask() { read -r -p "$2" "$1" </dev/tty || die 'Нужен интерактивный SSH-терминал.'; }
[[ $EUID -eq 0 ]] || die 'Запустите: sudo bash install.sh [домен]'
[[ -r /dev/tty ]] || die 'Нужен интерактивный SSH-терминал.'
echo 'Мастер установки: 3x-ui + VLESS-XHTTP + HTTPS-сайт'
echo 'Отвечайте на вопросы; Enter выбирает значение в квадратных скобках.'
[[ -r /etc/os-release && -d /run/systemd/system ]] || die 'Нужна Linux-система с systemd.'
. /etc/os-release
case "$ID:$VERSION_ID" in
  ubuntu:20.04*|ubuntu:22.04*|ubuntu:24.04*|ubuntu:26.04*|debian:11*|debian:12*|debian:13*|debian:testing|debian:unstable) ;;
  *)
    if [[ "${ID_LIKE:-}" == *debian* || "${ID_LIKE:-}" == *ubuntu* || "$ID" == "debian" || "$ID" == "ubuntu" ]]; then
      echo "[+] Обнаружена совместимая система: $ID ($VERSION_ID). Продолжаем установку..."
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
echo '1 — чистый VPS: установить 3x-ui, XHTTP и сайт'
echo '2 — 3x-ui уже установлена: сохранить всё и добавить XHTTP и сайт'
while true; do
  ask INSTALL_MODE 'Режим установки [1]: '
  INSTALL_MODE=${INSTALL_MODE:-1}
  [[ "$INSTALL_MODE" == 1 || "$INSTALL_MODE" == 2 ]] && break
  echo 'Введите 1 или 2.'
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
if [[ "$INSTALL_MODE" == 1 ]]; then targets+=(/etc/x-ui /usr/local/x-ui); fi
for target in "${targets[@]}"; do
  [[ ! -e "$target" && ! -L "$target" ]] || die "Обнаружено $target. Выберите режим дополнения или чистый VPS."
done
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
[[ -n "$DOMAIN" ]] || ask DOMAIN 'Домен (без https:// и пути): '
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
  echo "Резервная копия сохранена: $STATE/backup"
fi
STAGE=dependencies
export DEBIAN_FRONTEND=noninteractive
echo 'Установка зависимостей. При занятости APT ждём до 300 секунд; блокировки не удаляются.'
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
  echo "DNS для $DOMAIN:"
  if getent ahosts "$DOMAIN"; then break; fi
  echo 'Домен пока не разрешается. Исправьте DNS или укажите другой домен.'
fi
ask DOMAIN 'Введите домен заново (или исправленный прежний домен): '
done
echo "Домен: $DOMAIN. Все A/AAAA должны указывать на этот VPS; откройте TCP 80 и $PUBLIC_TLS_PORT в панели хостинга."
if [[ "$INSTALL_MODE" == 1 ]]; then echo 'Для новой панели также нужен TCP 8443 с административных IP.'; fi
echo 'Для этой инструкции используйте DNS only. Неверную AAAA удалите или исправьте.'
ADMIN_IP=${SSH_CONNECTION:-}
ADMIN_IP=${ADMIN_IP%% *}
ADMIN_IP=${ADMIN_IP:-${SSH_CLIENT:-}}
ADMIN_IP=${ADMIN_IP%% *}
while true; do
echo 'Белый список разрешает доступ к новому VPN; для новой панели применяется тот же список. Сайт открыт всем.'
echo 'Укажите внешние IP устройств/сетей ДО включения VPN. При смене IP список потребуется обновить.'
ask WHITELIST "Разрешённые IP/CIDR через запятую, all — без ограничения [${ADMIN_IP:-обязательно указать}]: "
WHITELIST=${WHITELIST:-$ADMIN_IP}
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
echo 'Проверьте адреса и повторите ввод.'
done
PRESETS=('Tokyo|Kissa Studio|Specialty coffee|Japanese minimalism' 'Berlin|Bauhaus Lab|Architecture|Sustainable design' 'Paris|Atelier Lumiere|Botanical fragrances|Handcrafted scents')
IFS='|' read -r DEF_CITY DEF_BRAND DEF_NICHE DEF_VIBE <<< "${PRESETS[RANDOM % ${#PRESETS[@]}]}"
echo 'Для ИИ используется нейросеть Pollinations (бесплатно, без обязательных ключей).'
while true; do
  echo 'Создание сайта: 1 — нейросеть (ИИ), 2 — встроенный шаблон, 3 — свой HTML-файл.'
  ask SITE_MODE 'Ваш выбор [1]: '
  SITE_MODE=${SITE_MODE:-1}
  case "$SITE_MODE" in
    1)
      read -r -s -p 'API-ключ Pollinations (Enter — бесплатно без ключа): ' POLLINATIONS_API_KEY </dev/tty
      echo
      break
      ;;
    2) POLLINATIONS_API_KEY=''; break ;;
    3) POLLINATIONS_API_KEY=''; break ;;
    *) echo 'Введите 1, 2 или 3.' ;;
  esac
done
if [[ "$SITE_MODE" == 3 ]]; then
  echo 'Скрипт работает на VPS и не видит файлы вашего компьютера.'
  echo 'Оставьте это окно SSH открытым. Во ВТОРОМ окне PowerShell/терминала НА КОМПЬЮТЕРЕ выполните:'
  echo '  scp -P 22 "C:\Users\ВашеИмя\Desktop\index.html" user@IP_СЕРВЕРА:~/my-site.html'
  echo 'На macOS/Linux пример: scp -P 22 ~/Desktop/index.html user@IP_СЕРВЕРА:~/my-site.html'
  echo 'Замените путь на свой, user/IP — на SSH-логин и адрес VPS, 22 — на ваш SSH-порт.'
  echo 'Либо подключитесь через WinSCP/FileZilla по SFTP и перетащите HTML в домашний каталог SSH-пользователя.'
  echo 'После загрузки вернитесь сюда и укажите ПОЛНЫЙ ПУТЬ НА VPS:'
  echo '  /home/user/my-site.html (для root: /root/my-site.html). Путь C:\... сюда не подходит.'
  echo 'Нужен один UTF-8 HTML-файл: встроенные CSS/JS и картинки data: либо абсолютные HTTPS-ссылки.'
  echo 'Отдельные локальные картинки, CSS и JS этим режимом не переносятся. PHP/обработка форм не устанавливаются.'
  while true; do
    ask HTML_SOURCE 'Полный путь загруженного HTML на VPS: '
    if [[ "$HTML_SOURCE" == /* && -f "$HTML_SOURCE" && -r "$HTML_SOURCE" && -s "$HTML_SOURCE" ]]; then break; fi
    echo 'Файл не найден, пуст или недоступен. Завершите загрузку и повторите ввод.'
  done
else
  ask CITY "Город [$DEF_CITY]: "; CITY=${CITY:-$DEF_CITY}
  ask BRAND "Название [$DEF_BRAND]: "; BRAND=${BRAND:-$DEF_BRAND}
  ask NICHE "Сфера деятельности [$DEF_NICHE]: "; NICHE=${NICHE:-$DEF_NICHE}
  ask VIBE "Ключевые слова / стиль [$DEF_VIBE]: "; VIBE=${VIBE:-$DEF_VIBE}
fi
if [[ -n "${POLLINATIONS_API_KEY:-}" ]]; then
  ask AI_MODEL 'ID текстовой модели из каталога Pollinations [openai]: '
  export AI_MODEL=${AI_MODEL:-openai}
else
  export AI_MODEL=openai
fi
if [[ "$INSTALL_MODE" == 2 ]]; then
  ask EXISTING_PANEL_URL 'Текущий URL панели с секретным путём (http:// или https://): '
  read -r -s -p 'API-токен существующей панели (Settings → API Tokens): ' TOKEN </dev/tty
  echo
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
if [[ "$SITE_MODE" == 3 ]]; then
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
if '\x00' in text or not re.search(r'<html\b', text, re.I) or not re.search(r'</html\s*>', text, re.I):
    raise SystemExit('Нужен полный HTML-документ с <html> и </html>')
destination.write_bytes(raw)
print('Готовый сайт скопирован без изменения содержимого. Исходный файл сохранён.')
PY_UPLOAD
  then break; fi
  echo 'Исправьте или заново загрузите HTML и повторите ввод.'
  ask HTML_SOURCE 'Полный путь HTML на VPS: '
  done
else
POLLINATIONS_API_KEY="$POLLINATIONS_API_KEY" python3 - "$CITY" "$BRAND" "$NICHE" "$VIBE" "$WEBROOT/index.html" <<'PY_SITE'
import sys, os, json, re, urllib.request, html, signal
from datetime import datetime
from pathlib import Path

city = sys.argv[1].strip() if len(sys.argv) > 1 else "Tokyo"
brand = sys.argv[2].strip() if len(sys.argv) > 2 else "Kissa Studio"
niche = sys.argv[3].strip() if len(sys.argv) > 3 else "Specialty Coffee"
vibe = sys.argv[4].strip() if len(sys.argv) > 4 else "Modern minimal"

ai_success = False
html_content = ""

prompt = (
    f"Create a complete, modern, responsive single-page HTML5 website for a company named '{brand}'.\n"
    f"Location / City: '{city}'.\n"
    f"Industry / Niche: '{niche}'.\n"
    f"Atmosphere / Brand Vibe: '{vibe}'.\n\n"
    f"STRICT REQUIREMENTS:\n"
    f"1. LANGUAGE: The entire website copy (page title, navigation menu, hero headline, about section, 3-4 feature/service cards, contact address, current-year copyright footer) MUST be written in the primary native/official language of the city '{city}' (for example: Japanese for Tokyo, German for Berlin, French for Paris, Italian for Rome, Spanish for Madrid, Russian for Russian cities, etc.).\n"
    f"2. DESIGN: High-end, polished, responsive UI with modern CSS embedded inside <style>. Use clean typography (Inter or modern sans-serif), soft shadows, gradient accents, responsive flexbox/grid layout, smooth scrolling, and mobile responsiveness.\n"
    f"3. ASSETS: Use CSS illustrations and inline styles. No JavaScript, forms, iframes, external scripts or tracking.\n"
    f"4. CONTENT: Include city '{city}', no contact forms, no invented phone numbers or street addresses, no social links.\n"
    f"5. OUTPUT FORMAT: Return ONLY the raw HTML code starting with <!DOCTYPE html> and ending with </html>. Do NOT include markdown blocks, backticks, or conversational text."
)

def ai_deadline(signum, frame):
    raise TimeoutError("Превышено общее время запроса ИИ")

try:
    if hasattr(signal, "SIGALRM"):
        signal.signal(signal.SIGALRM, ai_deadline)
        signal.alarm(120)
    key = os.environ.get("POLLINATIONS_API_KEY", "").strip()
    if key:
        url = "https://gen.pollinations.ai/v1/chat/completions"
        payload = json.dumps({
            "messages": [
                {"role": "system", "content": "You are an expert front-end web developer. You return ONLY valid raw HTML5 code starting with <!DOCTYPE html> and ending with </html>. Never use markdown code blocks or explanations."},
                {"role": "user", "content": prompt}
            ],
            "model": os.environ.get("AI_MODEL", "openai")
        }).encode("utf-8")

        req = urllib.request.Request(url, data=payload, headers={
            "Content-Type": "application/json", "Authorization": "Bearer " + key, "User-Agent": "Mozilla/5.0"})
        with urllib.request.urlopen(req, timeout=45) as resp:
            raw = resp.read(2_000_001)
            if len(raw) > 2_000_000:
                raise ValueError("Ответ ИИ слишком большой")
            result = json.loads(raw)
            cleaned = result["choices"][0]["message"]["content"].strip()
    else:
        url = "https://text.pollinations.ai/"
        payload = json.dumps({
            "messages": [
                {"role": "system", "content": "You are an expert front-end web developer. You return ONLY valid raw HTML5 code starting with <!DOCTYPE html> and ending with </html>. Never use markdown code blocks or explanations."},
                {"role": "user", "content": prompt}
            ],
            "model": "openai"
        }).encode("utf-8")

        req = urllib.request.Request(url, data=payload, headers={
            "Content-Type": "application/json", "User-Agent": "Mozilla/5.0"})
        with urllib.request.urlopen(req, timeout=45) as resp:
            raw = resp.read(2_000_001)
            if len(raw) > 2_000_000:
                raise ValueError("Ответ ИИ слишком большой")
            cleaned = raw.decode("utf-8", errors="replace").strip()

    cleaned = re.sub(r'^```(?:html)?\s*', '', cleaned, flags=re.IGNORECASE)
    cleaned = re.sub(r'\s*```$', '', cleaned).strip()
    if "<html" in cleaned.lower():
        if "</html>" not in cleaned.lower():
            cleaned += "\n</body>\n</html>"
        cleaned = re.sub(r'(?is)<script\b[^>]*>.*?</script>', '', cleaned)
        cleaned = re.sub(r'(?is)<iframe\b[^>]*>.*?</iframe>', '', cleaned)
        html_content = cleaned
        ai_success = True
        print("[+] Сайт сгенерирован нейросетью!")
    else:
        raise ValueError("В ответе нейросети отсутствует тег <html")
except Exception as e:
    print(f"[!] Внимание: шлюз ИИ временно недоступен ({type(e).__name__}). Активирован встроенный генератор...")

finally:
    if hasattr(signal, "SIGALRM"):
        signal.alarm(0)

if not ai_success or not html_content:
    is_cyrillic = any('\u0400' <= char <= '\u04FF' for char in f"{city} {brand} {niche} {vibe}")
    
    if is_cyrillic:
        lang = "ru"
        nav_services = "Услуги"
        nav_about = "О компании"
        nav_contact = "Контакты"
        btn_contact = "Связаться с нами"
        sec_services_title = "Наши услуги и преимущества"
        sec_services_sub = "Безупречные стандарты и индивидуальный подход"
        card1_t = "Высокое качество"
        card1_d = f"Каждый проект компании {brand} создается с вниманием к мельчайшим деталям."
        card2_t = "Надежность и опыт"
        card2_d = f"Проверенная репутация в г. {city} и строгое следование вашим пожеланиям."
        card3_t = "Индивидуальный сервис"
        card3_d = "Персональный менеджер, прозрачные условия сотрудничества и честные цены."
        about_title = f"О компании {brand}"
        about_text1 = f"Мы развиваем направление «{niche}» в г. {city}, объединяя многолетний опыт, современный подход и ценности: {vibe}."
        about_text2 = "Наша миссия — превосходить ожидания и создавать продукт, которым мы гордимся каждый день."
        contact_title = "Локация и график"
        contact_addr = f"📍 г. {city}"
        contact_hours = "🕒 Пн-Вс: 09:00 — 21:00"
        contact_phone = "Контактная информация уточняется"
        footer_copy = f"© {datetime.now().year} {brand} ({city}). Все права защищены."
        footer_sub = "Информационная страница."
    else:
        lang = "en"
        nav_services = "Services"
        nav_about = "About Us"
        nav_contact = "Contact"
        btn_contact = "Get in Touch"
        sec_services_title = "Signature Services & Excellence"
        sec_services_sub = "Designed for those who appreciate true craft and dedication"
        card1_t = "Premium Quality"
        card1_d = f"Every creation at {brand} embodies perfection and modern craft."
        card2_t = "Authentic Heritage"
        card2_d = f"Proudly serving {city} with genuine passion and community trust."
        card3_t = "Bespoke Experience"
        card3_d = "Tailored solutions, seamless service, and unmatched customer care."
        about_title = f"About {brand}"
        about_text1 = f"Specializing in {niche} in {city}, we blend time-tested mastery with modern vision: {vibe}."
        about_text2 = "Our philosophy is built on excellence, sustainability, and creating memorable experiences for our guests and partners."
        contact_title = "Location & Hours"
        contact_addr = f"📍 {city}"
        contact_hours = "🕒 Mon-Sun: 09:00 — 21:00"
        contact_phone = f"Contact details coming soon"
        footer_copy = f"© {datetime.now().year} {brand} ({city}). All rights reserved."
        footer_sub = "Information page."

    html_content = f'''<!DOCTYPE html>
<html lang="{lang}">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>{html.escape(brand)} — {html.escape(niche)} ({html.escape(city)})</title>
    <link rel="preconnect" href="https://fonts.googleapis.com">
    <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
    <link href="https://fonts.googleapis.com/css2?family=Plus+Jakarta+Sans:wght@300;400;500;600;700;800&display=swap" rel="stylesheet">
    <style>
        :root {{
            --primary: #2563eb;
            --primary-dark: #1d4ed8;
            --accent: #38bdf8;
            --dark: #0f172a;
            --bg: #f8fafc;
            --card-bg: #ffffff;
            --text: #334155;
            --text-dark: #0f172a;
            --border: #e2e8f0;
        }}
        * {{ margin: 0; padding: 0; box-sizing: border-box; font-family: 'Plus Jakarta Sans', sans-serif; }}
        body {{ background-color: var(--bg); color: var(--text); line-height: 1.6; overflow-x: hidden; }}
        header {{
            position: fixed; top: 0; left: 0; right: 0; background: rgba(255, 255, 255, 0.92);
            backdrop-filter: blur(12px); z-index: 100; border-bottom: 1px solid var(--border);
        }}
        .nav-container {{
            max-width: 1200px; margin: 0 auto; display: flex; justify-content: space-between;
            align-items: center; padding: 1.1rem 2rem;
        }}
        .logo {{ font-size: 1.35rem; font-weight: 800; color: var(--text-dark); text-decoration: none; letter-spacing: -0.5px; }}
        .logo span {{ color: var(--primary); }}
        .nav-links {{ display: flex; gap: 2rem; list-style: none; }}
        .nav-links a {{ text-decoration: none; color: var(--text); font-weight: 500; font-size: 0.95rem; transition: color 0.2s; }}
        .nav-links a:hover {{ color: var(--primary); }}
        .hero {{
            padding: 9rem 2rem 6rem; max-width: 1100px; margin: 0 auto; text-align: center;
        }}
        .badge {{
            display: inline-block; background: #eff6ff; color: var(--primary); padding: 0.4rem 1.2rem;
            border-radius: 9999px; font-size: 0.85rem; font-weight: 600; margin-bottom: 1.5rem;
            border: 1px solid #dbeafe;
        }}
        .hero h1 {{
            font-size: 3.2rem; color: var(--text-dark); margin-bottom: 1.25rem;
            font-weight: 800; line-height: 1.15; letter-spacing: -1px;
        }}
        .hero p {{ font-size: 1.3rem; max-width: 720px; margin: 0 auto 2.5rem; color: #64748b; font-weight: 400; }}
        .btn {{
            display: inline-block; background: var(--primary); color: #fff; padding: 0.95rem 2.4rem;
            border-radius: 9999px; text-decoration: none; font-weight: 600; font-size: 1.05rem;
            box-shadow: 0 10px 25px -5px rgba(37, 99, 235, 0.4); transition: all 0.25s ease;
        }}
        .btn:hover {{ background: var(--primary-dark); transform: translateY(-2px); box-shadow: 0 15px 30px -5px rgba(37, 99, 235, 0.5); }}
        .section {{ max-width: 1200px; margin: 0 auto; padding: 5rem 2rem; }}
        .section-title {{ text-align: center; margin-bottom: 3.5rem; }}
        .section-title h2 {{ font-size: 2.3rem; color: var(--text-dark); margin-bottom: 0.75rem; font-weight: 800; letter-spacing: -0.5px; }}
        .section-title p {{ color: #64748b; font-size: 1.1rem; }}
        .grid {{ display: grid; grid-template-columns: repeat(auto-fit, minmax(min(100%, 280px), 1fr)); gap: 2rem; }}
        .card {{
            background: var(--card-bg); padding: 2.5rem; border-radius: 1.25rem;
            border: 1px solid var(--border); box-shadow: 0 4px 6px -1px rgba(0,0,0,0.02);
            transition: all 0.25s ease;
        }}
        .card:hover {{ transform: translateY(-5px); box-shadow: 0 20px 25px -5px rgba(0,0,0,0.06); border-color: #cbd5e1; }}
        .card h3 {{ font-size: 1.35rem; margin-bottom: 1rem; color: var(--text-dark); font-weight: 700; }}
        .card p {{ color: #64748b; font-size: 1rem; line-height: 1.6; }}
        .about-box {{
            background: #fff; border-radius: 1.5rem; padding: 3.5rem;
            border: 1px solid var(--border);
            display: grid; grid-template-columns: 1.2fr 0.8fr; gap: 3.5rem; align-items: center;
            box-shadow: 0 10px 20px -5px rgba(0,0,0,0.04);
        }}
        .info-card {{
            background: #f8fafc; border-radius: 1.25rem; padding: 2.2rem;
            border: 1px solid var(--border); border-left: 5px solid var(--primary);
        }}
        .info-card h3 {{ margin-bottom: 1rem; color: var(--text-dark); font-size: 1.25rem; }}
        .info-card p {{ color: #475569; margin-bottom: 0.75rem; font-size: 0.95rem; }}
        footer {{
            background: var(--dark); color: #94a3b8; padding: 4rem 2rem; margin-top: 6rem;
            text-align: center; font-size: 0.95rem; border-top: 1px solid #1e293b;
        }}
        @media(max-width: 768px) {{
            .hero h1 {{ font-size: 2.3rem; }}
            .about-box {{ grid-template-columns: 1fr; padding: 2rem; gap: 2rem; }}
            .nav-links {{ display: none; }}
        }}
    </style>
</head>
<body>
    <header>
        <div class="nav-container">
            <a href="#" class="logo">{html.escape(brand)} <span>.</span></a>
            <ul class="nav-links">
                <li><a href="#services">{nav_services}</a></li>
                <li><a href="#about">{nav_about}</a></li>
                <li><a href="#contacts">{nav_contact}</a></li>
            </ul>
        </div>
    </header>

    <main>
        <section class="hero">
            <div class="badge">{html.escape(city)} &bull; {html.escape(niche)}</div>
            <h1>{html.escape(brand)}</h1>
            <p>{html.escape(vibe)}</p>
            <a href="#contacts" class="btn">{btn_contact}</a>
        </section>

        <section class="section" id="services">
            <div class="section-title">
                <h2>{sec_services_title}</h2>
                <p>{sec_services_sub}</p>
            </div>
            <div class="grid">
                <div class="card">
                    <h3>{html.escape(card1_t)}</h3>
                    <p>{html.escape(card1_d)}</p>
                </div>
                <div class="card">
                    <h3>{html.escape(card2_t)}</h3>
                    <p>{html.escape(card2_d)}</p>
                </div>
                <div class="card">
                    <h3>{html.escape(card3_t)}</h3>
                    <p>{html.escape(card3_d)}</p>
                </div>
            </div>
        </section>

        <section class="section" id="about">
            <div class="about-box">
                <div>
                    <h2 style="font-size: 2rem; color: var(--text-dark); margin-bottom: 1.25rem; font-weight: 800;">{html.escape(about_title)}</h2>
                    <p style="margin-bottom: 1.25rem; color: #475569; font-size: 1.05rem;">
                        {html.escape(about_text1)}
                    </p>
                    <p style="color: #475569; font-size: 1.05rem;">
                        {html.escape(about_text2)}
                    </p>
                </div>
                <div class="info-card">
                    <h3>{contact_title}</h3>
                    <p>{html.escape(contact_addr)}</p>
                    <p>{html.escape(contact_hours)}</p>
                    <p>{html.escape(contact_phone)}</p>
                </div>
            </div>
        </section>
    </main>

    <footer id="contacts">
        <p>{html.escape(footer_copy)}</p>
        <p style="margin-top: 0.5rem; opacity: 0.7;">{html.escape(footer_sub)}</p>
    </footer>
</body>
</html>'''

destination = Path(sys.argv[5])
temporary = destination.with_suffix('.html.tmp')
temporary.write_text(html_content, encoding='utf-8')
temporary.replace(destination)
print(f"[+] Сайт записан: {len(html_content.encode('utf-8'))} байт")
PY_SITE
fi
unset POLLINATIONS_API_KEY
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
  echo 'Сертификат не выпущен. Проверьте A/AAAA, доступность порта 80 и сообщение Certbot.'
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
SITE_CSP="add_header Content-Security-Policy \"default-src 'none'; style-src 'unsafe-inline' https://fonts.googleapis.com; font-src https://fonts.gstatic.com; img-src https: data:; script-src 'none'; connect-src 'none'; form-action 'none'; frame-ancestors 'none'; base-uri 'none'\" always;"
# User-supplied static HTML may intentionally contain its own JS/CSS.
if [[ "$SITE_MODE" == 3 ]]; then SITE_CSP=''; fi
cat >> "$NGINX_SITE" <<EOF
server {
    listen $PUBLIC_TLS_PORT ssl http2;
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
        satisfy all;
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
    satisfy all;
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
  sed -i "/listen $PUBLIC_TLS_PORT ssl http2;/a\\    listen [::]:$PUBLIC_TLS_PORT ssl http2;" "$NGINX_SITE"
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
# Exercise the whole local chain: SOCKS -> VLESS/XHTTP -> Nginx TLS -> Xray -> Internet.
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
XRAY=/usr/local/x-ui/bin/xray-linux-$ARCH
"$XRAY" run -test -config "$WORK/test-client.json"
"$XRAY" run -config "$WORK/test-client.json" > "$STATE/selftest.log" 2>&1 &
TEST_PID=$!
ready=0
for ((n=0; n<15; n++)); do
  if [[ -n "$(ss -H -ltn "sport = :$TEST_PORT")" ]]; then ready=1; break; fi
  sleep 1
done
[[ $ready == 1 ]] || die "Тестовый Xray не запустился: $STATE/selftest.log"
curl -fsS --noproxy '' --proxy "socks5h://127.0.0.1:$TEST_PORT" \
  --connect-timeout 15 --max-time 45 https://example.com/ -o /dev/null
kill "$TEST_PID"
wait "$TEST_PID" || true
TEST_PID=''
echo 'Локальные проверки пройдены: Nginx, доверенный TLS, панель и передача HTTPS через VLESS-XHTTP.'
echo 'Теперь проверьте подключение с телефона/ПК: внешняя сеть и клиент здесь не проверены.'
sed -i '/^Статус:/d' "$STATE/access.txt"
printf '\nСтатус: локальные проверки пройдены. Требуется внешний тест клиента.\n' >> "$STATE/access.txt"
cat "$STATE/access.txt" "$STATE/connection.txt"
qrencode -t ANSIUTF8 < "$STATE/connection.txt" || true
echo "Данные сохранены в $STATE (доступ только root)."
