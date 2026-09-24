#!/usr/bin/env bash
# Fresh VPS installer. See README.md for requirements and recovery.
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
[[ -r /etc/os-release && -d /run/systemd/system ]] || die 'Нужна Linux-система с systemd.'
. /etc/os-release
case "$ID:$VERSION_ID" in
  ubuntu:22.04|ubuntu:24.04|debian:12|debian:13) ;;
  *) die 'Поддерживаются Ubuntu 22.04/24.04, Debian 12/13.' ;;
esac
case "$(uname -m)" in
  x86_64) ARCH=amd64; SHA=6a85c110a04a727613c933c54ae602b8d37dab8876c6e20a6d46623010dd9d3c ;;
  aarch64) ARCH=arm64; SHA=2dd601a32426fb19b0eafdffaead374a9cdb66be4dfb39407f9f50fa4e7234e7 ;;
  *) die 'Поддерживаются только amd64 и arm64.' ;;
esac
readonly VERSION=v3.8.5
readonly STATE=/etc/vless-installer
readonly WEBROOT=/var/www/vless-site
readonly ACME=/var/www/vless-acme
readonly XUI=/usr/local/x-ui/x-ui
readonly PANEL_PORT=2053
readonly PUBLIC_PANEL_PORT=8443
readonly XRAY_PORT=10000
for target in "$STATE" /etc/x-ui /usr/local/x-ui "$WEBROOT" /etc/nginx/sites-available/vless-installer; do
  [[ ! -e "$target" ]] || die "Обнаружено $target. Нужен чистый VPS: повторный запуск не перезаписывает существующую установку."
done
command -v ss >/dev/null || die 'Не найдена ss (пакет iproute2).'
for port in 80 443 2096 "$PANEL_PORT" "$PUBLIC_PANEL_PORT" "$XRAY_PORT"; do
  [[ -z "$(ss -H -ltn "sport = :$port")" ]] || die "Порт $port занят. Сначала выясните, какой службой."
done
exec 9>/run/vless-installer.lock
flock -n 9 || die 'Другой экземпляр установщика уже работает.'
DOMAIN=${1:-}
[[ -n "$DOMAIN" ]] || ask DOMAIN 'Домен (без https:// и пути): '
STAGE=dependencies
export DEBIAN_FRONTEND=noninteractive
echo 'Установка зависимостей. При занятости APT ждём до 300 секунд; блокировки не удаляются.'
apt-get -o DPkg::Lock::Timeout=300 update
apt-get -o DPkg::Lock::Timeout=300 install -y ca-certificates curl nginx certbot python3 openssl qrencode tar
DOMAIN=$(python3 - "$DOMAIN" <<'PY_DOMAIN'
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
)
echo "Домен: $DOMAIN. Все A/AAAA должны указывать на этот VPS; TCP 80/443/8443 должны быть доступны в панели хостинга."
echo 'Для этой инструкции используйте DNS only. Неверную AAAA удалите или исправьте.'
getent ahosts "$DOMAIN" || die 'Домен не разрешается. Исправьте DNS и запустите снова.'
ADMIN_IP=${SSH_CONNECTION:-}
ADMIN_IP=${ADMIN_IP%% *}
ADMIN_IP=${ADMIN_IP:-${SSH_CLIENT:-}}
ADMIN_IP=${ADMIN_IP%% *}
ask WHITELIST "IP/CIDR для панели через запятую, all — всем [${ADMIN_IP:-обязательно указать}]: "
WHITELIST=${WHITELIST:-$ADMIN_IP}
ACL=$(python3 - "$WHITELIST" <<'PY_ACL'
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
)
PRESETS=('Tokyo|Kissa Studio|Specialty coffee|Japanese minimalism' 'Berlin|Bauhaus Lab|Architecture|Sustainable design' 'Paris|Atelier Lumiere|Botanical fragrances|Handcrafted scents')
IFS='|' read -r DEF_CITY DEF_BRAND DEF_NICHE DEF_VIBE <<< "${PRESETS[RANDOM % ${#PRESETS[@]}]}"
ask CITY "Город [$DEF_CITY]: "; CITY=${CITY:-$DEF_CITY}
ask BRAND "Название [$DEF_BRAND]: "; BRAND=${BRAND:-$DEF_BRAND}
ask NICHE "Сфера деятельности [$DEF_NICHE]: "; NICHE=${NICHE:-$DEF_NICHE}
ask VIBE "Ключевые слова / стиль [$DEF_VIBE]: "; VIBE=${VIBE:-$DEF_VIBE}
echo 'Для ИИ используется Pollinations. Параметры сайта отправляются сервису; действуют его тарифы и лимиты.'
read -r -s -p 'API-ключ Pollinations (Enter — локальный шаблон): ' POLLINATIONS_API_KEY </dev/tty
echo
export POLLINATIONS_API_KEY
if [[ -n "$POLLINATIONS_API_KEY" ]]; then
  ask AI_MODEL 'ID текстовой модели из каталога Pollinations [openai]: '
  export AI_MODEL=${AI_MODEL:-openai}
fi
WORK=$(mktemp -d /tmp/vless-installer.XXXXXXXX)
install -d -m 700 "$STATE"
install -d -m 755 "$WEBROOT" "$ACME" "$ACME/.well-known" "$ACME/.well-known/acme-challenge"
STAGE=site
timeout 150 python3 - "$CITY" "$BRAND" "$NICHE" "$VIBE" "$WEBROOT/index.html" <<'PY_SITE'
import sys, os, json, re, urllib.request, html
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

try:
    key = os.environ.get("POLLINATIONS_API_KEY", "").strip()
    if not key:
        raise ValueError("API-ключ не задан")
    url = "https://gen.pollinations.ai/v1/chat/completions"
    payload = json.dumps({
        "messages": [
            {"role": "system", "content": "You are an expert front-end web developer. You return ONLY valid raw HTML5 code starting with <!DOCTYPE html> and ending with </html>. Never use markdown code blocks or explanations."},
            {"role": "user", "content": prompt}
        ],
        "model": os.environ.get("AI_MODEL", "openai")
    }).encode("utf-8")

    req = urllib.request.Request(url, data=payload, headers={
        "Content-Type": "application/json", "Authorization": "Bearer " + key})
    with urllib.request.urlopen(req, timeout=45) as resp:
        raw = resp.read(2_000_001)
        if len(raw) > 2_000_000:
            raise ValueError("Ответ ИИ слишком большой")
        result = json.loads(raw)
        cleaned = result["choices"][0]["message"]["content"].strip()
        cleaned = re.sub(r'^```(?:html)?\s*', '', cleaned, flags=re.IGNORECASE)
        cleaned = re.sub(r'\s*```$', '', cleaned).strip()
        if not re.match(r'(?is)<!doctype\s+html\s*>', cleaned) or not re.search(r'(?is)</html>\s*$', cleaned):
            raise ValueError("Получен неполный HTML")
        if re.search(r'(?is)<(?:script|iframe|object|embed|form)\b|\son[a-z]+\s*=|javascript:|http-equiv\s*=', cleaned):
            raise ValueError("ИИ добавил запрещённое активное содержимое")
        html_content = cleaned
        ai_success = True
        print("[+] Сайт сгенерирован нейросетью; отправка форм и JavaScript отключены.")
except Exception as e:
    print(f"[!] Внимание: шлюз ИИ временно недоступен ({type(e).__name__}). Активирован встроенный генератор...")

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
unset POLLINATIONS_API_KEY
chmod 644 "$WEBROOT/index.html"
STAGE=certificate
# ACME webroot remains available for automatic renewals without stopping Nginx.
cat > /etc/nginx/sites-available/vless-installer <<EOF
server {
    listen 80;
    server_name $DOMAIN;
    root $ACME;
    location ^~ /.well-known/acme-challenge/ { default_type text/plain; try_files \$uri =404; }
    location / { return 301 https://$DOMAIN\$request_uri; }
}
EOF
if [[ -s /proc/net/if_inet6 ]]; then
  sed -i '/listen 80;/a\    listen [::]:80;' /etc/nginx/sites-available/vless-installer
fi
ln -s /etc/nginx/sites-available/vless-installer /etc/nginx/sites-enabled/vless-installer
nginx -t
systemctl enable --now nginx
systemctl reload nginx
# Preserve SSH rules and current firewall policy. Never turn UFW on blindly.
if command -v ufw >/dev/null && ufw status | grep -q '^Status: active'; then
  ufw allow 80/tcp
  ufw allow 443/tcp
  # Access is restricted independently by the Nginx ACL, including IPv6.
  ufw allow "$PUBLIC_PANEL_PORT/tcp"
fi
certbot certonly --webroot -w "$ACME" -d "$DOMAIN" --cert-name "$DOMAIN" \
  --non-interactive --agree-tos --register-unsafely-without-email
CERT_FILE=/etc/letsencrypt/live/$DOMAIN/fullchain.pem
KEY_FILE=/etc/letsencrypt/live/$DOMAIN/privkey.pem
[[ -s "$CERT_FILE" && -s "$KEY_FILE" ]]
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
XHTTP_PATH=/$(openssl rand -hex 16)/
CLIENT_UUID=$(python3 -c 'import uuid; print(uuid.uuid4())')
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
python3 - "$CLIENT_UUID" "$DOMAIN" "$XHTTP_PATH" "$XRAY_PORT" "$WORK/inbound.json" <<'PY_INBOUND'
import json, sys
from pathlib import Path
uid, domain, path, port, out = sys.argv[1:]
client = dict(id=uid, email='initial-client', enable=True, flow='', limitIp=0,
              totalGB=0, expiryTime=0, tgId=0, subId='', reset=0)
inbound = dict(remark='VLESS-XHTTP', enable=True, expiryTime=0, total=0,
    listen='127.0.0.1', port=int(port), protocol='vless', tag='vless-xhttp',
    settings=dict(clients=[client], decryption='none', fallbacks=[]),
    streamSettings=dict(network='xhttp', security='none',
                        externalProxy=[dict(dest=domain, port=443, forceTls='tls',
                                            sni=domain, alpn=['http/1.1'], fingerprint='chrome')],
                        xhttpSettings=dict(host=domain, path=path, mode='packet-up')),
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
systemctl restart x-ui
STAGE=https
cat >> /etc/nginx/sites-available/vless-installer <<EOF
server {
    listen 443 ssl http2;
    server_name $DOMAIN;
    ssl_certificate $CERT_FILE;
    ssl_certificate_key $KEY_FILE;
    ssl_protocols TLSv1.2 TLSv1.3;
    root $WEBROOT;
    index index.html;
    location ^~ $XHTTP_PATH {
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
        add_header Content-Security-Policy "default-src 'none'; style-src 'unsafe-inline' https://fonts.googleapis.com; font-src https://fonts.gstatic.com; img-src https: data:; script-src 'none'; connect-src 'none'; form-action 'none'; frame-ancestors 'none'; base-uri 'none'" always;
        add_header X-Content-Type-Options nosniff always;
        try_files \$uri \$uri/ =404;
    }
}
server {
    listen $PUBLIC_PANEL_PORT ssl;
    server_name $DOMAIN;
    ssl_certificate $CERT_FILE;
    ssl_certificate_key $KEY_FILE;
    ssl_protocols TLSv1.2 TLSv1.3;
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
if [[ -s /proc/net/if_inet6 ]]; then
  sed -i '/listen 443 ssl http2;/a\    listen [::]:443 ssl http2;' /etc/nginx/sites-available/vless-installer
  sed -i "/listen $PUBLIC_PANEL_PORT ssl;/a\\    listen [::]:$PUBLIC_PANEL_PORT ssl;" /etc/nginx/sites-available/vless-installer
fi
nginx -t
systemctl reload nginx
install -d -m 755 /etc/letsencrypt/renewal-hooks/deploy
cat > /etc/letsencrypt/renewal-hooks/deploy/vless-nginx <<'HOOK'
#!/bin/sh
set -e
/usr/sbin/nginx -t
/bin/systemctl reload nginx
HOOK
chmod 755 /etc/letsencrypt/renewal-hooks/deploy/vless-nginx
systemctl enable --now certbot.timer
STAGE=verification
systemctl is-active --quiet nginx x-ui
curl -fsS --noproxy '*' --max-time 15 --resolve "$DOMAIN:443:127.0.0.1" "https://$DOMAIN/" -o /dev/null
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
query = urlencode(dict(encryption='none', security='tls', sni=domain, fp='chrome',
                       alpn='http/1.1', type='xhttp', host=domain, path=path, mode='packet-up'))
link = f'vless://{uid}@{domain}:443?{query}#VLESS-XHTTP'
Path(directory, 'connection.txt').write_text(link+'\n', encoding='utf-8')
client = dict(log=dict(loglevel='warning'), inbounds=[dict(listen='127.0.0.1', port=10808,
    protocol='socks', settings=dict(auth='noauth', udp=True))], outbounds=[dict(
    protocol='vless', settings=dict(vnext=[dict(address=domain, port=443,
        users=[dict(id=uid, encryption='none')])]), streamSettings=dict(network='xhttp',
    security='tls', tlsSettings=dict(serverName=domain, fingerprint='chrome', alpn=['http/1.1']),
    xhttpSettings=dict(host=domain, path=path, mode='packet-up')))])
Path(directory, 'client.json').write_text(json.dumps(client, indent=2), encoding='utf-8')
PY_CLIENT
chmod 600 "$STATE"/*
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
printf '\nСтатус: локальные проверки пройдены. Требуется внешний тест клиента.\n' >> "$STATE/access.txt"
cat "$STATE/access.txt" "$STATE/connection.txt"
qrencode -t ANSIUTF8 < "$STATE/connection.txt" || true
echo "Данные сохранены в $STATE (доступ только root)."
