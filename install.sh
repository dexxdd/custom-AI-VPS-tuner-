#!/bin/bash
set -e

# ==========================================================================
# Скрипт автоматического развертывания VLESS-XHTTP + 3X-UI + AI Сайт-Маскировка
# Отказоустойчивая версия (с защитой от зависаний, сбоев и ошибок пользователя)
# ==========================================================================

# Обработчик непредвиденных ошибок
handle_error() {
  local exit_code=$?
  local line_no=$1
  local cmd=$2
  echo ""
  echo "=========================================================================="
  echo "[-] Произошла ошибка (код: $exit_code) на строке $line_no: $cmd"
  echo "[-] Установка была приостановлена."
  echo "[-] Вы можете исправить причину и перезапустить установку в любой момент:"
  echo "    sudo bash install.sh"
  echo "=========================================================================="
  exit $exit_code
}
trap 'handle_error $LINENO "$BASH_COMMAND"' ERR

# Проверка прав root
if [ "$EUID" -ne 0 ]; then
  echo "[-] Ошибка: запустите скрипт с правами суперпользователя (sudo bash)!"
  exit 1
fi

clear
echo "=========================================================================="
echo "    АВТОМАТИЧЕСКАЯ УСТАНОВКА 3X-UI + VLESS XHTTP + AI САЙТ-МАСКИРОВКА     "
echo "=========================================================================="
echo ""

# Функция ожидания снятия блокировки APT (частая проблема на свежих VPS)
wait_for_apt_lock() {
  local max_wait=60
  local count=0
  while fuser /var/lib/dpkg/lock >/dev/null 2>&1 || fuser /var/lib/apt/lists/lock >/dev/null 2>&1 || fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; do
    if [ $count -eq 0 ]; then
      echo "[*] Обнаружена блокировка менеджера пакетов (apt lock). Ожидание освобождения фоновым процессом..."
    fi
    sleep 2
    count=$((count + 2))
    if [ $count -ge $max_wait ]; then
      echo "[!] Превышено время ожидания фонового обновления. Принудительное снятие блокировки..."
      killall -9 apt-get apt unattended-upgrade 2>/dev/null || true
      rm -f /var/lib/apt/lists/lock /var/cache/apt/archives/lock /var/lib/dpkg/lock* 2>/dev/null || true
      dpkg --configure -a 2>/dev/null || true
      break
    fi
  done
}

# Отключение конфликтующих служб (например, Apache, если он был предустановлен хостингом)
systemctl stop apache2 2>/dev/null || true
systemctl disable apache2 2>/dev/null || true

# Определение внешнего IP сервера для подсказок DNS
echo "[*] Определение внешнего IP-адреса сервера..."
SERVER_IP=$(curl -s4 --connect-timeout 5 icanhazip.com || curl -s4 --connect-timeout 5 ifconfig.me || curl -s4 --connect-timeout 5 api.ipify.org || true)

CLI_DOMAIN="$1"

# Функция запроса и проверки домена с защитой от ошибок и зацикливаний
prompt_and_validate_domain() {
  while true; do
    echo ""
    echo "--------------------------------------------------------------------------"
    echo "                     ПРИВЯЗКА ДОМЕНА К СЕРВЕРУ (DNS)                      "
    echo "--------------------------------------------------------------------------"
    if [ -n "$SERVER_IP" ]; then
      echo " 🌐 Внешний IP вашего VPS: $SERVER_IP"
    else
      echo " 🌐 Внешний IP сервера: [будет определен позже]"
    fi
    echo ""
    echo " 📌 ТРЕБОВАНИЯ ДЛЯ УСПЕШНОГО ВЫПУСКА SSL-СЕРТИФИКАТА:"
    echo " 1. Домен (или поддомен) должен быть заранее направлен на IP этого сервера:"
    echo "    • Тип записи:  A"
    echo "    • Имя / Host:  @ (для основного домена) или имя поддомена (например: vpn)"
    echo "    • Значение:    ${SERVER_IP:-<IP_ВАШЕГО_СЕРВЕРА>}"
    echo "    • TTL:         Авто или 300 (5 минут)"
    echo ""
    echo " 2. Если DNS управляется через Cloudflare:"
    echo "    • Проксирование (оранжевое облако) ОБЯЗАТЕЛЬНО должно быть ВЫКЛЮЧЕНО!"
    echo "    • Режим записи: DNS only (серый значок облака)."
    echo "    (Иначе Let's Encrypt не сможет подтвердить владение доменом и выдаст ошибку)."
    echo ""
    echo " 3. Если запись добавлена только что:"
    echo "    • Распространение DNS в мире может занимать от 2 до 15 минут."
    echo "--------------------------------------------------------------------------"
    echo ""

    if [ -n "$CLI_DOMAIN" ]; then
      DOMAIN="$CLI_DOMAIN"
      CLI_DOMAIN=""
      echo "Используется домен из аргументов запуска: $DOMAIN"
    else
      printf "Введите ваш домен (например, your-domain.com): "
      read -r DOMAIN < /dev/tty
    fi

    # Очистка домена: удаляем пробелы, http://, https://, слэши и переводим в нижний регистр
    DOMAIN=$(echo "$DOMAIN" | sed -e 's|^[^/]*//||' -e 's|/.*$||' | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')

    if [ -z "$DOMAIN" ]; then
      echo "[-] Домен не указан! Пожалуйста, укажите имя домена."
      continue
    fi

    echo ""
    echo "[*] Проверка привязки домена $DOMAIN в системе DNS..."
    RESOLVED_IP=$(getent ahosts "$DOMAIN" 2>/dev/null | awk '{print $1}' | head -n 1)
    if [ -z "$RESOLVED_IP" ]; then
      RESOLVED_IP=$(python3 -c "import socket; print(socket.gethostbyname('$DOMAIN'))" 2>/dev/null || true)
    fi

    if [ -n "$RESOLVED_IP" ]; then
      if [ -n "$SERVER_IP" ] && [ "$RESOLVED_IP" = "$SERVER_IP" ]; then
        echo " [+] Отлично! Домен $DOMAIN корректно направлен на этот сервер ($SERVER_IP)."
        break
      else
        echo " [!] ВНИМАНИЕ: Домен $DOMAIN сейчас указывает на IP: $RESOLVED_IP"
        echo "     (А IP этого сервера: ${SERVER_IP:-неизвестен})"
        echo "     Возможные причины:"
        echo "     1) В Cloudflare включен Proxy (оранжевое облако) — переключите в 'DNS only'."
        echo "     2) Запись A изменена недавно и DNS-кэш еще обновляется."
        echo "     3) Опечатка в IP-адресе в панели управления DNS вашего хостинга."
        echo ""
        echo "Выберите действие:"
        echo " 1) Ввести другой домен (или исправить опечатку)"
        echo " 2) Продолжить установку всё равно (я уверен, что DNS обновится)"
        echo " 3) Выйти из скрипта для настройки DNS"
        printf "Ваш выбор [1-3, Enter для 2]: "
        read -r DNS_CHOICE < /dev/tty
        DNS_CHOICE="${DNS_CHOICE:-2}"
        if [ "$DNS_CHOICE" = "1" ]; then
          continue
        elif [ "$DNS_CHOICE" = "3" ]; then
          echo "[-] Установка остановлена для настройки DNS."
          exit 0
        else
          break
        fi
      fi
    else
      echo " [!] ВНИМАНИЕ: Домен $DOMAIN пока не отвечает в DNS (не резолвится в IP)."
      echo "     Возможные причины:"
      echo "     1) Запись A добавлена только что и DNS еще не обновился (подождите 5-10 мин)."
      echo "     2) В названии домена допущена опечатка."
      echo ""
      echo "Выберите действие:"
      echo " 1) Ввести домен заново"
      echo " 2) Продолжить установку всё равно"
      echo " 3) Выйти из скрипта"
      printf "Ваш выбор [1-3, Enter для 2]: "
      read -r DNS_CHOICE < /dev/tty
      DNS_CHOICE="${DNS_CHOICE:-2}"
      if [ "$DNS_CHOICE" = "1" ]; then
        continue
      elif [ "$DNS_CHOICE" = "3" ]; then
        echo "[-] Установка остановлена."
        exit 0
      else
        break
      fi
    fi
  done
}

prompt_and_validate_domain

# Определение IP админа из текущего SSH-подключения
CURRENT_ADMIN_IP=$(echo "$SSH_CLIENT" | awk '{print $1}')
if [ -z "$CURRENT_ADMIN_IP" ]; then
  CURRENT_ADMIN_IP=$(who am i 2>/dev/null | awk '{print $5}' | tr -d '()')
fi

echo ""
echo "--------------------------------------------------------------------------"
echo "        НАСТРОЙКА БЕЛОГО СПИСКА ФАЕРВОЛА ДЛЯ АДМИН-ПАНЕЛИ 3X-UI           "
echo "--------------------------------------------------------------------------"
if [ -n "$CURRENT_ADMIN_IP" ]; then
  echo " [+] Ваш текущий IP-адрес подключения (SSH): $CURRENT_ADMIN_IP"
else
  echo " [!] Не удалось автоматически определить ваш IP-адрес подключения."
fi
echo ""
echo " Формат ввода:"
if [ -n "$CURRENT_ADMIN_IP" ]; then
  echo " • Разрешить вход только с вашего текущего IP ($CURRENT_ADMIN_IP):"
  echo "   👉 Просто нажмите [Enter]"
  echo ""
fi
echo " • Указать один или несколько своих IP/подсетей через запятую:"
echo "   👉 Пример: 203.0.113.195, 198.51.100.0/24"
echo ""
echo " • Открыть вход в панель со всех IP мира (без белого списка):"
echo "   👉 Напишите: all"
echo "--------------------------------------------------------------------------"

if [ -n "$CURRENT_ADMIN_IP" ]; then
  printf " Введите IP/подсети [нажмите Enter для %s]: " "$CURRENT_ADMIN_IP"
  read -r INPUT_IPS < /dev/tty
  WHITELIST_IPS="${INPUT_IPS:-$CURRENT_ADMIN_IP}"
else
  printf " Введите IP/подсети через запятую (или 'all'): "
  read -r WHITELIST_IPS < /dev/tty
  WHITELIST_IPS="${WHITELIST_IPS:-all}"
fi

echo ""
echo "[+] Выбранный домен: $DOMAIN"
echo "[+] Белый список панели: $WHITELIST_IPS"
echo "[+] IP сервера: $SERVER_IP"
echo ""

echo "[1/6] Обновление пакетов и установка зависимостей..."
wait_for_apt_lock
export DEBIAN_FRONTEND=noninteractive
apt-get update -y || { echo "[!] Предупреждение: некоторые репозитории недоступны, продолжаем..."; }
wait_for_apt_lock
apt-get install -y curl wget git nginx certbot jq sqlite3 ufw uuid-runtime qrencode python3 openssl

# Функция выпуска SSL-сертификата с интерактивным выбором при ошибках
issue_ssl_certificate() {
  local attempt=1

  while true; do
    echo ""
    echo "[2/6] Получение SSL-сертификата Let's Encrypt для $DOMAIN (попытка $attempt)..."
    systemctl stop nginx apache2 2>/dev/null || true
    fuser -k 80/tcp 2>/dev/null || true
    sleep 1

    CERT_FILE="/etc/letsencrypt/live/$DOMAIN/fullchain.pem"
    KEY_FILE="/etc/letsencrypt/live/$DOMAIN/privkey.pem"

    if certbot certonly --standalone -d "$DOMAIN" --non-interactive --agree-tos --register-unsafely-without-email --preferred-challenges http; then
      if [ -f "$CERT_FILE" ] && [ -f "$KEY_FILE" ]; then
        echo "[+] SSL-сертификат Let's Encrypt успешно получен!"
        return 0
      fi
    fi

    echo ""
    echo "[-] Не удалось выпустить SSL-сертификат Let's Encrypt для $DOMAIN."
    echo "    Возможные причины:"
    echo "    1) В Cloudflare включен Proxy (оранжевое облако) — переключите в 'DNS only'."
    echo "    2) Запись A в DNS еще не обновилась глобально."
    echo "    3) Превышен лимит запросов Let's Encrypt."
    echo ""
    echo "Выберите действие:"
    echo " 1) Повторить попытку получения сертификата сейчас"
    echo " 2) Ввести другой домен"
    echo " 3) Создать надежный самоподписанный SSL (установка завершится без задержек)"
    echo " 4) Прервать установку"
    printf "Ваш выбор [1-4, Enter для 1]: "
    read -r SSL_CHOICE < /dev/tty
    SSL_CHOICE="${SSL_CHOICE:-1}"

    case "$SSL_CHOICE" in
      1)
        attempt=$((attempt + 1))
        echo "[*] Повторная попытка через 3 секунды..."
        sleep 3
        ;;
      2)
        prompt_and_validate_domain
        attempt=1
        ;;
      3)
        echo "[*] Генерация надежного самоподписанного SSL-сертификата..."
        mkdir -p "/etc/letsencrypt/live/$DOMAIN"
        CERT_FILE="/etc/letsencrypt/live/$DOMAIN/fullchain.pem"
        KEY_FILE="/etc/letsencrypt/live/$DOMAIN/privkey.pem"
        openssl req -x509 -nodes -newkey rsa:2048 -days 365 \
          -keyout "$KEY_FILE" \
          -out "$CERT_FILE" \
          -subj "/CN=$DOMAIN" 2>/dev/null
        echo "[+] Самоподписанный SSL-сертификат успешно создан!"
        return 0
        ;;
      *)
        echo "[-] Установка прервана пользователем."
        exit 1
        ;;
    esac
  done
}

issue_ssl_certificate

echo ""
echo "=========================================================================="
echo "          [3/6] ГЕНЕРАТОР САЙТА-ПРИКРЫТИЯ (AI MASK GENERATOR)             "
echo "=========================================================================="
echo " Нейросеть создаст уникальный HTML5-сайт компании под ключ:"
echo " • Автоматический подбор языка под выбранный город (Tokyo -> японский,"
echo "   Berlin -> немецкий, Paris -> французский, Rome -> итальянский и т.д.)"
echo " • Профессиональный адаптивный дизайн, 2026 год, контакты и форма"
echo " • Без регистрации, без API-ключей, полностью бесплатно"
echo "--------------------------------------------------------------------------"
echo " [СОВЕТ] Если нажать [Enter] на любом поле, скрипт сам выберет случайный"
echo "         крутой вариант компании мирового уровня!"
echo "=========================================================================="
echo ""

# Авторандом: подбор случайного качественного пресета компании
RANDOM_PRESET=$(python3 -c "
import random
presets = [
    ('Tokyo', 'Kissa Neo-Tokyo', 'Specialty Coffee & Japanese Bakery', 'Artisanal roasting with minimalist aesthetics'),
    ('Berlin', 'Bauhaus Studio Lab', 'Modern Architecture & Sustainable Design', 'Brutalist minimalism with eco-friendly innovation'),
    ('Paris', 'Atelier Lumière', 'Haute Parfumerie & Botanical Scents', 'Refined Parisian luxury handcrafted with passion'),
    ('Rome', 'Trattoria Antica Roma', 'Authentic Cucina & Natural Wine Bar', 'Warm family hospitality and traditional wood-fired recipes'),
    ('Amsterdam', 'Velocitas Cycle Lab', 'Custom Urban Bicycles & Commuter Gear', 'Dutch craft engineering for sustainable city life'),
    ('Zurich', 'Helvetia Wealth Advisors', 'Private Wealth & Financial Technologies', 'Swiss precision, discreet trust and high-end security'),
    ('New York', 'Apex Creative Studio', 'Digital Media & Brand Strategy Agency', 'Fast-paced metropolitan energy with cutting-edge tech'),
    ('Madrid', 'Estudio Sol Creativo', 'Diseño de Interiores y Arquitectura', 'Luz mediterránea, sostenibilidad y vanguardia'),
    ('Seoul', 'Gangnam Sound & Vision', 'Audio Engineering & Creative Media', 'High-tech K-innovations and state-of-the-art studio'),
    ('Vienna', 'Kaiser & Franz Kaffeehaus', 'Specialty Austrian Roastery & Bakery', 'Imperial Viennese coffee heritage with artisanal craft')
]
p = random.choice(presets)
print('|'.join(p))
")

IFS='|' read -r DEF_CITY DEF_BRAND DEF_NICHE DEF_VIBE <<< "$RANDOM_PRESET"

echo " [Форма параметров сайта]"
printf " 1. Город / Локация (например, Tokyo, Berlin, Paris, Москва) [Enter для '%s']: " "$DEF_CITY"
read -r INPUT_CITY < /dev/tty
CITY=$(echo "${INPUT_CITY:-$DEF_CITY}" | xargs)
CITY="${CITY:-$DEF_CITY}"

printf " 2. Название компании / Бренда [Enter для '%s']: " "$DEF_BRAND"
read -r INPUT_BRAND < /dev/tty
BRAND=$(echo "${INPUT_BRAND:-$DEF_BRAND}" | xargs)
BRAND="${BRAND:-$DEF_BRAND}"

printf " 3. Сфера деятельности / Ниша [Enter для '%s']: " "$DEF_NICHE"
read -r INPUT_NICHE < /dev/tty
NICHE=$(echo "${INPUT_NICHE:-$DEF_NICHE}" | xargs)
NICHE="${NICHE:-$DEF_NICHE}"

printf " 4. Атмосфера / Фишка компании [Enter для '%s']: " "$DEF_VIBE"
read -r INPUT_VIBE < /dev/tty
VIBE=$(echo "${INPUT_VIBE:-$DEF_VIBE}" | xargs)
VIBE="${VIBE:-$DEF_VIBE}"

echo ""
echo "[+] Выбранные параметры:"
echo "    • Город:     $CITY"
echo "    • Бренд:     $BRAND"
echo "    • Ниша:      $NICHE"
echo "    • Атмосфера: $VIBE"
echo ""
echo "[*] Генерация сайта нейросетью... Пожалуйста, подождите (10-25 сек)..."

mkdir -p /var/www/html
rm -rf /var/www/html/* /var/www/html/.* 2>/dev/null || true

python3 - "$CITY" "$BRAND" "$NICHE" "$VIBE" << 'PYEOF'
import sys, os, json, re, urllib.request, html

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
    f"1. LANGUAGE: The entire website copy (page title, navigation menu, hero headline, about section, 3-4 feature/service cards, contact address, working form, 2026 copyright footer) MUST be written in the primary native/official language of the city '{city}' (for example: Japanese for Tokyo, German for Berlin, French for Paris, Italian for Rome, Spanish for Madrid, Russian for Russian cities, etc.).\n"
    f"2. DESIGN: High-end, polished, responsive UI with modern CSS embedded inside <style>. Use clean typography (Inter or modern sans-serif), soft shadows, gradient accents, responsive flexbox/grid layout, smooth scrolling, and mobile responsiveness.\n"
    f"3. IMAGERY: Use high-quality Unsplash image URLs with relevant keywords (e.g. https://images.unsplash.com/...).\n"
    f"4. REALISM: Include realistic local phone number format, realistic street address in '{city}', working contact form, social links.\n"
    f"5. OUTPUT FORMAT: Return ONLY the raw HTML code starting with <!DOCTYPE html> and ending with </html>. Do NOT include markdown blocks, backticks, or conversational text."
)

try:
    url = "https://text.pollinations.ai/"
    payload = json.dumps({
        "messages": [
            {"role": "system", "content": "You are an expert front-end web developer. You return ONLY valid raw HTML5 code starting with <!DOCTYPE html> and ending with </html>. Never use markdown code blocks or explanations."},
            {"role": "user", "content": prompt}
        ],
        "model": "openai"
    }).encode("utf-8")

    req = urllib.request.Request(url, data=payload, headers={"Content-Type": "application/json", "User-Agent": "Mozilla/5.0"})
    with urllib.request.urlopen(req, timeout=30) as resp:
        raw = resp.read().decode("utf-8")
        cleaned = raw.strip()
        cleaned = re.sub(r'^```(?:html)?\s*', '', cleaned, flags=re.IGNORECASE)
        cleaned = re.sub(r'\s*```$', '', cleaned).strip()
        if "<html" in cleaned.lower():
            if "</html>" not in cleaned.lower():
                cleaned += "\n</body>\n</html>"
            html_content = cleaned
            ai_success = True
            print("[+] Сайт успешно сгенерирован нейросетью!")
except Exception as e:
    print(f"[!] Внимание: шлюз ИИ временно недоступен ({e}). Активирован встроенный генератор...")

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
        contact_addr = f"📍 г. {city}, Центральный проспект, 12"
        contact_hours = "🕒 Пн-Вс: 09:00 — 21:00"
        contact_phone = "📞 Телефон: +7 (800) 555-35-35"
        footer_copy = f"&copy; 2026 {brand} ({city}). Все права защищены."
        footer_sub = "Официальный сайт компании. Политика конфиденциальности."
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
        contact_addr = f"📍 Central Avenue, {city}"
        contact_hours = "🕒 Mon-Sun: 09:00 — 21:00"
        contact_phone = f"📞 Inquiries: +1 (800) 555-0199"
        footer_copy = f"&copy; 2026 {brand} ({city}). All rights reserved."
        footer_sub = "Official corporate website. Privacy Policy & Terms."

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
        .grid {{ display: grid; grid-template-columns: repeat(auto-fit, minmax(320px, 1fr)); gap: 2rem; }}
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
                    <p>{contact_addr}</p>
                    <p>{contact_hours}</p>
                    <p>{contact_phone}</p>
                </div>
            </div>
        </section>
    </main>

    <footer id="contacts">
        <p>{footer_copy}</p>
        <p style="margin-top: 0.5rem; opacity: 0.7;">{footer_sub}</p>
    </footer>
</body>
</html>'''

with open('/var/www/html/index.html', 'w', encoding='utf-8') as f:
    f.write(html_content)

print(f"[+] Сайт успешно размещен в /var/www/html/index.html ({len(html_content)} байт)")
PYEOF

# Гарантия создания файла index.html
if [ ! -s /var/www/html/index.html ]; then
  cat << EOF > /var/www/html/index.html
<!DOCTYPE html>
<html><head><meta charset="utf-8"><title>$BRAND</title></head>
<body style="font-family:sans-serif;text-align:center;padding:50px;">
<h1>$BRAND</h1><p>$NICHE ($CITY)</p><p>$VIBE</p>
</body></html>
EOF
fi

chown -R www-data:www-data /var/www/html 2>/dev/null || true
chmod -R 755 /var/www/html 2>/dev/null || true

echo "[4/6] Запуск веб-сервера Nginx на порту 80..."
cat << 'EOF' > /etc/nginx/sites-available/default
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;
    root /var/www/html;
    index index.html;

    location / {
        try_files $uri $uri/ =404;
    }
}
EOF

nginx -t 2>/dev/null || { echo "[!] Предупреждение: тест Nginx выдал замечание, продолжаем..."; }
systemctl restart nginx 2>/dev/null || systemctl start nginx 2>/dev/null || true
systemctl enable nginx 2>/dev/null || true

echo "[5/6] Установка 3X-UI панели и настройка VLESS-XHTTP..."
export XUI_NONINTERACTIVE=1

install_3x_ui() {
  local attempts=0
  while [ $attempts -lt 3 ]; do
    if bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh); then
      return 0
    fi
    attempts=$((attempts + 1))
    echo "[!] Повторная попытка загрузки 3X-UI ($attempts/3)..."
    sleep 3
  done
  echo "[-] Ошибка: не удалось загрузить установщик 3X-UI."
  return 1
}

install_3x_ui

# Подбор гарантированно свободного случайного порта для панели 3X-UI
find_free_panel_port() {
  local candidate
  while true; do
    candidate=$(shuf -i 20000-65000 -n 1 2>/dev/null || python3 -c "import random; print(random.randint(20000, 65000))")
    
    # Исключаем системные порты (80, 443, 22 и активный порт SSH)
    local active_ssh
    active_ssh=$(ss -tlnp 2>/dev/null | grep -E 'sshd|dropbear' | awk '{print $4}' | awk -F':' '{print $NF}' | head -n 1)
    active_ssh="${active_ssh:-22}"
    if [ "$candidate" = "80" ] || [ "$candidate" = "443" ] || [ "$candidate" = "$active_ssh" ] || [ "$candidate" = "22" ]; then
      continue
    fi
    
    # Проверка утилитой ss (не слушает ли уже кто-то этот порт)
    if ss -tlnp 2>/dev/null | grep -q ":${candidate}\b"; then
      continue
    fi
    
    # Проверка fuser
    if fuser "${candidate}/tcp" >/dev/null 2>&1; then
      continue
    fi
    
    # Строгая проверка через Python: реальная попытка bind сокета
    if python3 -c "import socket; s = socket.socket(socket.AF_INET, socket.SOCK_STREAM); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1); s.bind(('', $candidate)); s.close()" >/dev/null 2>&1; then
      echo "$candidate"
      return 0
    fi
  done
}

PANEL_PORT=$(find_free_panel_port)
PANEL_USER="admin"
PANEL_PASS=$(openssl rand -hex 6)
PANEL_PATH=$(openssl rand -hex 8)

echo "[+] Настройка защищенного порта и учетных данных 3X-UI..."
x-ui setting -port "$PANEL_PORT" -username "$PANEL_USER" -password "$PANEL_PASS" -webBasePath "/$PANEL_PATH/"
systemctl restart x-ui
sleep 2

CLIENT_UUID=$(uuidgen 2>/dev/null || python3 -c "import uuid; print(uuid.uuid4())")

python3 -c "
import sqlite3, json, time, os

domain = '$DOMAIN'
cert_file = '$CERT_FILE'
key_file = '$KEY_FILE'
client_uuid = '$CLIENT_UUID'
db_path = '/etc/x-ui/x-ui.db'

# Ожидание создания базы данных службой x-ui
for _ in range(15):
    if os.path.exists(db_path):
        break
    time.sleep(1)

conn = sqlite3.connect(db_path)
c = conn.cursor()

# Проверка готовности таблицы inbounds
for _ in range(10):
    c.execute(\"SELECT name FROM sqlite_master WHERE type='table' AND name='inbounds'\")
    if c.fetchone():
        break
    time.sleep(1)

c.execute('DELETE FROM inbounds')

# Проверка наличия таблицы client_traffics
c.execute(\"SELECT name FROM sqlite_master WHERE type='table' AND name='client_traffics'\")
has_traffics = bool(c.fetchone())
if has_traffics:
    c.execute('DELETE FROM client_traffics')

settings = json.dumps({
    'clients': [{'id': client_uuid, 'email': f'user@{domain}', 'flow': ''}],
    'decryption': 'none',
    'fallbacks': [{'dest': 80}]
})

stream_settings = json.dumps({
    'network': 'xhttp',
    'security': 'tls',
    'tlsSettings': {
        'serverName': domain,
        'fingerprint': 'edge',
        'certificates': [{
            'certificateFile': cert_file,
            'keyFile': key_file
        }],
        'alpn': ['http/1.1'],
        'settings': {
            'fingerprint': 'edge'
        }
    },
    'xhttpSettings': {
        'mode': 'auto',
        'host': domain,
        'path': '/api/',
        'xPaddingBytes': '100-1000'
    }
})

sniffing = json.dumps({
    'enabled': True,
    'destOverride': ['http', 'tls', 'quic', 'fakedns']
})

c.execute('''
    INSERT INTO inbounds (user_id, up, down, total, remark, enable, expiry_time, listen, port, protocol, settings, stream_settings, sniffing)
    VALUES (1, 0, 0, 0, 'VLESS-XHTTP', 1, 0, '', 443, 'vless', ?, ?, ?)
''', (settings, stream_settings, sniffing))

inbound_id = c.lastrowid
if has_traffics:
    c.execute('''
        INSERT INTO client_traffics (inbound_id, enable, email, up, down, expiry_time, total, reset)
        VALUES (?, 1, ?, 0, 0, 0, 0, 0)
    ''', (inbound_id, f'user@{domain}'))

conn.commit()
conn.close()
"

fuser -k 443/tcp 2>/dev/null || true
killall -9 xray 2>/dev/null || true
systemctl restart x-ui
sleep 2

echo "[6/6] Настройка фаервола UFW (защита панели и предотвращение блокировки SSH)..."
# Определение реального активного порта SSH
SSH_PORT=$(ss -tlnp 2>/dev/null | grep -E 'sshd|dropbear' | awk '{print $4}' | awk -F':' '{print $NF}' | head -n 1)
SSH_PORT="${SSH_PORT:-22}"

ufw default deny incoming
ufw default allow outgoing
ufw allow "$SSH_PORT"/tcp comment 'Active SSH' 2>/dev/null || true
if [ "$SSH_PORT" != "22" ]; then
  ufw allow 22/tcp comment 'Default SSH' 2>/dev/null || true
fi
ufw allow 80/tcp comment 'HTTP Web' 2>/dev/null || true
ufw allow 443/tcp comment 'HTTPS VLESS TLS' 2>/dev/null || true

CLEAN_IPS=$(echo "$WHITELIST_IPS" | tr -d '[:space:]')
if [ "$CLEAN_IPS" = "all" ] || [ -z "$CLEAN_IPS" ]; then
  echo "[+] Админ-панель открыта для всех IP"
  ufw allow "$PANEL_PORT"/tcp comment '3X-UI Public' 2>/dev/null || true
else
  IFS=',' read -ra ADDR_ARRAY <<< "$WHITELIST_IPS"
  for item in "${ADDR_ARRAY[@]}"; do
    ip=$(echo "$item" | xargs)
    if [ -n "$ip" ]; then
      echo "[+] Добавление в белый список UFW: $ip -> порт $PANEL_PORT"
      ufw allow from "$ip" to any port "$PANEL_PORT" proto tcp comment '3X-UI Whitelist' 2>/dev/null || true
    fi
  done
fi

ufw --force enable 2>/dev/null || true

VLESS_LINK="vless://${CLIENT_UUID}@${DOMAIN}:443?alpn=http%2F1.1&encryption=none&extra=%7B%22mode%22%3A%22auto%22%2C%22xPaddingBytes%22%3A%22100-1000%22%7D&fp=edge&host=${DOMAIN}&mode=auto&path=%2Fapi%2F&security=tls&sni=${DOMAIN}&type=xhttp&x_padding_bytes=100-1000#VLESS-XHTTP"

echo ""
echo "=========================================================================="
echo "                 УСТАНОВКА ПОЛНОСТЬЮ ЗАВЕРШЕНА!                          "
echo "=========================================================================="
echo ""
echo "Сайт-заглушка:   http://${DOMAIN}"
echo ""
echo "--- ВХОД В ПАНЕЛЬ 3X-UI ---"
echo "URL:             http://${SERVER_IP}:${PANEL_PORT}/${PANEL_PATH}/"
echo "Логин:           ${PANEL_USER}"
echo "Пароль:          ${PANEL_PASS}"
echo "Белый список:    ${WHITELIST_IPS}"
echo ""
echo "--- ВАША VLESS-ССЫЛКА ДЛЯ ПОДКЛЮЧЕНИЯ ---"
echo "${VLESS_LINK}"
echo ""
echo "--- QR-КОД ДЛЯ ИМПОРТА В ТЕЛЕФОН ---"
qrencode -t ANSIUTF8 "${VLESS_LINK}" 2>/dev/null || true
echo "=========================================================================="
