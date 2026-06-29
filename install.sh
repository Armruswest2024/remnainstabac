#!/bin/bash

# RemnaWave Panel Installation Script
# Version: 3.0.0 (Docker Compose Edition — basecode-compatible)
# Compatible with: https://github.com/CyberERROR/basecode
# Architecture: всё через Docker Compose (backend + postgres + nginx + subscription)

set -euo pipefail

# ===================== ЦВЕТА =====================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
PURPLE='\033[0;35m'
BOLD='\033[1m'
NC='\033[0m'

# ===================== ПУТИ =====================
APP_DIR="/opt/remnawave"
NGINX_DIR="${APP_DIR}/nginx"
SUB_DIR="${APP_DIR}/subscription"
BACKUP_DIR="${APP_DIR}/backups"
LOG_FILE="/var/log/remnawave_install.log"
CONFIG_FILE="${APP_DIR}/.env"
SUB_CONFIG_FILE="${SUB_DIR}/.env"

# ===================== ПЕРЕМЕННЫЕ =====================
DOMAIN=""
SUB_DOMAIN=""
EMAIL=""
WEB_SERVER="nginx"
ADMIN_USERNAME="admin"
ADMIN_PASSWORD=""
JWT_SECRET=""
DB_PASSWORD=""

# ===================== ЛОГИРОВАНИЕ =====================
log() {
    local level="$1"
    local message="$2"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo -e "${timestamp} [${level}] ${message}" | tee -a "$LOG_FILE"
}

info() { echo -e "${GREEN}[✓]${NC} $1"; log "INFO" "$1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; log "WARN" "$1"; }
error() { echo -e "${RED}[✗]${NC} $1"; log "ERROR" "$1"; }

spinner() {
    local pid=$1
    local delay=0.1
    local spinstr='|/-\'
    echo -n " "
    while kill -0 "$pid" 2>/dev/null; do
        local temp=${spinstr#?}
        printf " [%c]  " "$spinstr"
        local spinstr=$temp${spinstr%"$temp"}
        sleep $delay
        printf "\b\b\b\b\b\b"
    done
    printf "    \b\b\b\b"
}

run_quiet() {
    local msg=$1
    shift
    echo -ne "${YELLOW}${msg}...${NC}"
    "$@" >> "$LOG_FILE" 2>&1 &
    local pid=$!
    spinner $pid
    wait $pid
    local exit_code=$?
    if [ $exit_code -eq 0 ]; then
        echo -e "${GREEN} OK${NC}"
    else
        echo -e "${RED} ОШИБКА${NC}"
        error "Этап провалился (код $exit_code). Логи: $LOG_FILE"
        return 1
    fi
}

# ===================== ГЕНЕРАЦИЯ СЕКРЕТОВ =====================
generate_secret() {
    openssl rand -hex 32
}

generate_password() {
    openssl rand -hex 12
}

# ===================== ПРОВЕРКИ =====================
check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "Скрипт нужно запускать от root"
        exit 1
    fi
}

check_terminal() {
    if [ ! -t 0 ] && [ ! -e /dev/tty ]; then
        error "Запусти скрипт из терминала, а не через pipe"
        exit 1
    fi
}

check_requirements() {
    info "Проверяю системные требования..."

    # Проверка ОС
    if [[ ! -f /etc/debian_version ]]; then
        error "Поддерживаются только Debian/Ubuntu"
        exit 1
    fi

    # Проверка RAM (минимум 1GB)
    local ram=$(free -m | awk '/^Mem:/{print $2}')
    if [[ $ram -lt 1024 ]]; then
        warn "Мало RAM (${ram}MB). Рекомендуется минимум 1GB"
    fi

    # Проверка диска (минимум 5GB)
    local disk=$(df -BG / | awk 'NR==2 {print $4}' | sed 's/G//')
    if [[ $disk -lt 5 ]]; then
        error "Мало места на диске. Нужно минимум 5GB, доступно ${disk}GB"
        exit 1
    fi

    # Проверка портов
    for port in 80 443; do
        if ss -tlnp | grep -q ":$port "; then
            warn "Порт $port уже занят"
        fi
    done

    info "Системные требования OK"
}

# ===================== УСТАНОВКА DOCKER =====================
install_docker() {
    if command -v docker &> /dev/null; then
        info "Docker уже установлен"
        return 0
    fi

    info "Устанавливаю Docker..."
    run_quiet "Скачиваю Docker" bash -c "curl -fsSL https://get.docker.com -o /tmp/install-docker.sh && sh /tmp/install-docker.sh"
    rm -f /tmp/install-docker.sh
    export PATH=/usr/bin:/usr/local/bin:$PATH
    info "Docker установлен"
}

# ===================== СОЗДАНИЕ СТРУКТУРЫ =====================
create_directories() {
    info "Создаю директории..."
    mkdir -p "$APP_DIR" "$NGINX_DIR" "$SUB_DIR" "$BACKUP_DIR"
    info "Директории созданы"
}

# ===================== УСТАНОВКА =====================
configure_installation() {
    echo -e "\n${BLUE}=== Настройка установки ===${NC}\n"

    # Домен панели
    while true; do
        read -rp "Домен панели (напр. panel.example.com): " DOMAIN < /dev/tty
        DOMAIN=$(echo "$DOMAIN" | tr -d '\r' | sed 's/[^a-zA-Z0-9@._-]//g')
        if [[ -n "$DOMAIN" ]]; then break; fi
        error "Домен не может быть пустым"
    done

    # Поддомен подписки
    while true; do
        read -rp "Поддомен подписки (напр. sub.example.com): " SUB_DOMAIN < /dev/tty
        SUB_DOMAIN=$(echo "$SUB_DOMAIN" | tr -d '\r' | sed 's/[^a-zA-Z0-9@._-]//g')
        if [[ -n "$SUB_DOMAIN" && "$SUB_DOMAIN" != "$DOMAIN" ]]; then break; fi
        error "Поддомен должен быть другим и не пустым"
    done

    # Email для SSL
    while true; do
        read -rp "Email для SSL сертификатов: " EMAIL < /dev/tty
        EMAIL=$(echo "$EMAIL" | tr -d '\r' | sed 's/[^a-zA-Z0-9@._+-]//g')
        if [[ "$EMAIL" =~ ^[^@]+@[^@]+\.[^@]+$ ]]; then break; fi
        error "Введите корректный email"
    done

    # Веб-сервер
    echo -e "\nВыберите веб-сервер:"
    echo "  1) Nginx ( Docker)"
    echo "  2) Caddy (автоматический SSL)"
    read -rp "Выбор [1-2]: " web_choice < /dev/tty
    case "$web_choice" in
        2) WEB_SERVER="caddy" ;;
        *) WEB_SERVER="nginx" ;;
    esac

    # Подтверждение
    echo -e "\n${BLUE}=== Сводка ===${NC}"
    echo "Панель: https://${DOMAIN}"
    echo "Подписка: https://${SUB_DOMAIN}"
    echo "Email: ${EMAIL}"
    echo "Веб-сервер: ${WEB_SERVER}"
    echo ""
    read -rp "Продолжить? (yes/no): " confirm < /dev/tty
    if [[ "$confirm" != "yes" ]]; then
        info "Отменено"
        show_menu
        return
    fi
}

# ===================== УСТАНОВКА BACKEND =====================
install_backend() {
    info "Устанавливаю RemnaWave Backend..."

    cd "$APP_DIR"

    # Скачиваем docker-compose.yml и .env
    run_quiet "Скачиваю конфиги backend" bash -c "
        curl -sfL -o docker-compose.yml https://raw.githubusercontent.com/remnawave/backend/refs/heads/main/docker-compose-prod.yml &&
        curl -sfL -o .env https://raw.githubusercontent.com/remnawave/backend/refs/heads/main/.env.sample
    "

    # Генерируем секреты
    info "Генерирую секреты..."
    sed -i "s/^JWT_AUTH_SECRET=.*/JWT_AUTH_SECRET=$(generate_secret)/" .env
    sed -i "s/^JWT_API_TOKENS_SECRET=.*/JWT_API_TOKENS_SECRET=$(generate_secret)/" .env
    sed -i "s/^METRICS_PASS=.*/METRICS_PASS=$(generate_secret)/" .env
    sed -i "s/^WEBHOOK_SECRET_HEADER=.*/WEBHOOK_SECRET_HEADER=$(generate_secret)/" .env

    DB_PASSWORD=$(generate_password)
    sed -i "s/^POSTGRES_PASSWORD=.*/POSTGRES_PASSWORD=$DB_PASSWORD/" .env
    sed -i "s|^\(DATABASE_URL=\"postgresql://postgres:\)[^\@]*\(@.*\)|\1$DB_PASSWORD\2|" .env

    sed -i "s|^FRONT_END_DOMAIN=.*|FRONT_END_DOMAIN=$DOMAIN|" .env
    sed -i "s|^SUB_PUBLIC_DOMAIN=.*|SUB_PUBLIC_DOMAIN=$SUB_DOMAIN|" .env

    info "Backend сконфигурирован"
}

# ===================== УСТАНОВКА SUBSCRIPTION =====================
install_subscription() {
    info "Устанавливаю страницу подписки..."

    cd "$SUB_DIR"

    cat > docker-compose.yml <<'EOF'
services:
    remnawave-subscription-page:
        image: remnawave/subscription-page:latest
        container_name: remnawave-subscription-page
        hostname: remnawave-subscription-page
        restart: always
        env_file:
            - .env
        ports:
            - '127.0.0.1:3010:3010'
        networks:
            - remnawave-network

networks:
    remnawave-network:
        driver: bridge
        external: true
EOF

    cat > .env <<EOF
APP_PORT=3010
REMNAWAVE_PANEL_URL=http://remnawave:3000
META_TITLE="Subscription page"
META_DESCRIPTION="Subscription page description"
CUSTOM_SUB_PREFIX=
MARZBAN_LEGACY_LINK_ENABLED=false
MARZBAN_LEGACY_SECRET_KEY=
REMNAWAVE_API_TOKEN=
CADDY_AUTH_API_TOKEN=
EOF

    info "Subscription сконфигурирован"
}

# ===================== SSL СЕРТИФИКАТЫ =====================
install_ssl() {
    info "Устанавливаю SSL сертификаты..."

    # Устанавливаем acme.sh
    run_quiet "Устанавливаю acme.sh" bash -c "curl -fsSL https://get.acme.sh | sh -s email=\"$EMAIL\""
    export PATH="$HOME/.acme.sh:$PATH"

    # Настраиваем CA
    run_quiet "Настраиваю Let's Encrypt" ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt

    # SSL для панели
    run_quiet "Получаю сертификат для $DOMAIN" ~/.acme.sh/acme.sh --issue --standalone -d "$DOMAIN" \
        --key-file "${NGINX_DIR}/privkey.key" \
        --fullchain-file "${NGINX_DIR}/fullchain.pem"

    # SSL для подписки
    run_quiet "Получаю сертификат для $SUB_DOMAIN" ~/.acme.sh/acme.sh --issue --standalone -d "$SUB_DOMAIN" \
        --key-file "${NGINX_DIR}/subdomain_privkey.key" \
        --fullchain-file "${NGINX_DIR}/subdomain_fullchain.pem"

    # Проверка
    if [[ ! -f "${NGINX_DIR}/fullchain.pem" ]] || [[ ! -f "${NGINX_DIR}/subdomain_fullchain.pem" ]]; then
        error "Не удалось получить SSL сертификаты. Проверьте DNS и логи."
        return 1
    fi

    info "SSL сертификаты получены"
}

# ===================== NGINX =====================
setup_nginx() {
    info "Настраиваю Nginx..."

    cd "$NGINX_DIR"

    cat > nginx.conf <<EOF
upstream remnawave {
    server remnawave:3000;
}

upstream remnawave-subscription-page {
    server remnawave-subscription-page:3010;
}

server {
    server_name $DOMAIN;

    listen 443 ssl reuseport;
    listen [::]:443 ssl reuseport;
    http2 on;

    location /api/ {
        proxy_pass http://remnawave;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Forwarded-Host \$host;
        proxy_set_header X-Forwarded-Port \$server_port;
    }

    location / {
        proxy_http_version 1.1;
        proxy_pass http://remnawave;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384:DHE-RSA-CHACHA20-POLY1305;
    ssl_session_timeout 1d;
    ssl_session_cache shared:MozSSL:10m;
    ssl_session_tickets off;
    ssl_certificate "/etc/nginx/ssl/fullchain.pem";
    ssl_certificate_key "/etc/nginx/ssl/privkey.key";
    ssl_trusted_certificate "/etc/nginx/ssl/fullchain.pem";
    ssl_stapling on;
    ssl_stapling_verify on;
    resolver 1.1.1.1 1.0.0.1 8.8.8.8 8.8.4.4 208.67.222.222 208.67.220.220 valid=60s;
    resolver_timeout 2s;

    gzip on;
    gzip_vary on;
    gzip_proxied any;
    gzip_comp_level 6;
    gzip_buffers 16 8k;
    gzip_http_version 1.1;
    gzip_min_length 256;
    gzip_types application/atom+xml application/geo+json application/javascript application/x-javascript application/json application/ld+json application/manifest+json application/rdf+xml application/rss+xml application/xhtml+xml application/xml font/eot font/otf font/ttf image/svg+xml text/css text/javascript text/plain text/xml;
}

server {
    server_name $SUB_DOMAIN;

    listen 443 ssl;
    listen [::]:443 ssl;
    http2 on;

    location / {
        proxy_http_version 1.1;
        proxy_pass http://remnawave-subscription-page;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Forwarded-Host \$host;
        proxy_set_header X-Forwarded-Port \$server_port;
        proxy_send_timeout 60s;
        proxy_read_timeout 60s;
    }

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384:DHE-RSA-CHACHA20-POLY1305;
    ssl_session_timeout 1d;
    ssl_session_cache shared:MozSSL:10m;
    ssl_session_tickets off;
    ssl_certificate "/etc/nginx/ssl/subdomain_fullchain.pem";
    ssl_certificate_key "/etc/nginx/ssl/subdomain_privkey.key";
    ssl_trusted_certificate "/etc/nginx/ssl/subdomain_fullchain.pem";
    ssl_stapling on;
    ssl_stapling_verify on;
    resolver 1.1.1.1 1.0.0.1 8.8.8.8 8.8.4.4 208.67.222.222 208.67.220.220 valid=60s;
    resolver_timeout 2s;

    gzip on;
    gzip_vary on;
    gzip_proxied any;
    gzip_comp_level 6;
    gzip_buffers 16 8k;
    gzip_http_version 1.1;
    gzip_min_length 256;
    gzip_types application/atom+xml application/geo+json application/javascript application/x-javascript application/json application/ld+json application/manifest+json application/rdf+xml application/rss+xml application/xhtml+xml application/xml font/eot font/otf font/ttf image/svg+xml text/css text/javascript text/plain text/xml;
}

server {
    server_name _;
    listen 443 ssl default_server;
    listen [::]:443 ssl default_server;
    ssl_reject_handshake on;
}
EOF

    cat > docker-compose.yml <<EOF
services:
    remnawave-nginx:
        image: nginx:1.28
        container_name: remnawave-nginx
        hostname: remnawave-nginx
        volumes:
            - ./nginx.conf:/etc/nginx/conf.d/default.conf:ro
            - ./fullchain.pem:/etc/nginx/ssl/fullchain.pem:ro
            - ./privkey.key:/etc/nginx/ssl/privkey.key:ro
            - ./subdomain_fullchain.pem:/etc/nginx/ssl/subdomain_fullchain.pem:ro
            - ./subdomain_privkey.key:/etc/nginx/ssl/subdomain_privkey.key:ro
        restart: always
        ports:
            - '0.0.0.0:443:443'
        networks:
            - remnawave-network

networks:
    remnawave-network:
        name: remnawave-network
        driver: bridge
        external: true
EOF

    info "Nginx настроен"
}

# ===================== CADDY =====================
setup_caddy() {
    info "Настраиваю Caddy..."

    # Установка Caddy
    run_quiet "Устанавливаю Caddy" bash -c "
        curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg &&
        curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' > /etc/apt/sources.list.d/caddy-stable.list &&
        apt-get update -qq &&
        apt-get install -y -qq caddy
    "

    cat > /etc/caddy/Caddyfile <<EOF
${DOMAIN}, www.${DOMAIN} {
    reverse_proxy remnawave:3000

    header {
        X-Frame-Options "SAMEORIGIN"
        X-Content-Type-Options "nosniff"
        X-XSS-Protection "1; mode=block"
    }
}

${SUB_DOMAIN} {
    reverse_proxy remnawave-subscription-page:3010

    header {
        X-Frame-Options "SAMEORIGIN"
        X-Content-Type-Options "nosniff"
    }
}
EOF

    info "Caddy настроен"
}

# ===================== ЗАПУСК =====================
start_services() {
    info "Запускаю сервисы..."

    cd "$APP_DIR"
    run_quiet "Создаю Docker сеть" docker network create remnawave-network 2>/dev/null || true
    run_quiet "Запускаю Backend" docker compose up -d

    cd "$SUB_DIR"
    run_quiet "Запускаю Subscription" docker compose up -d

    cd "$NGINX_DIR"
    if [[ "$WEB_SERVER" == "nginx" ]]; then
        setup_nginx
        run_quiet "Запускаю Nginx" docker compose up -d
    else
        setup_caddy
        systemctl enable --now caddy
    fi

    info "Все сервисы запущены"
}

# ===================== СВЯЗКА ПОДПИСКИ =====================
link_subscription() {
    echo -e "\n${PURPLE}${BOLD}[*] Последний шаг — связка подписки с панелью${NC}"
    echo -e "${YELLOW}1. Зайди на панель: https://${DOMAIN}${NC}"
    echo -e "${YELLOW}2. Создай админа и войди${NC}"
    echo -e "${YELLOW}3. Настройки → API Токены → Создай новый токен${NC}"
    echo -e "${YELLOW}4. Скопируй токен сюда${NC}"

    local TOKEN=""
    while [ -z "$TOKEN" ]; do
        read -rp "Вставь токен: " TOKEN < /dev/tty
        TOKEN=$(echo "$TOKEN" | tr -d '\r' | xargs)
        if [ -z "$TOKEN" ]; then
            error "Токен не может быть пустым"
        fi
    done

    cd "$SUB_DIR"
    sed -i "s/^REMNAWAVE_API_TOKEN=.*/REMNAWAVE_API_TOKEN=$TOKEN/" .env
    docker compose down && docker compose up -d

    info "Подписка связана с панелью"
}

# ===================== ПОЛНАЯ УСТАНОВКА =====================
full_install() {
    check_requirements
    install_docker
    create_directories
    configure_installation
    install_backend
    install_subscription
    install_ssl
    start_services
    link_subscription

    echo -e "\n${GREEN}${BOLD}════════════════════════════════════════${NC}"
    echo -e "${GREEN}${BOLD}   Установка завершена! ✓${NC}"
    echo -e "${GREEN}${BOLD}════════════════════════════════════════${NC}"
    echo ""
    echo -e "Панель:        ${CYAN}https://${DOMAIN}${NC}"
    echo -e "Подписка:      ${CYAN}https://${SUB_DOMAIN}${NC}"
    echo -e "Конфигурация:  ${CONFIG_FILE}"
    echo -e "Логи:          ${LOG_FILE}"
    echo -e "Бэкапы:        ${BACKUP_DIR}/"
    echo ""
    echo -e "Полезные команды:"
    echo "  cd /opt/remnawave && docker compose ps"
    echo "  docker logs remnawave"
    echo "  docker logs remnawave-subscription-page"
    echo ""
}

# ===================== БЭКАП =====================
backup_panel() {
    info "Создаю резервную копию..."

    local backup_name="remnawave_backup_$(date +%Y%m%d_%H%M%S)"
    local backup_path="${BACKUP_DIR}/${backup_name}"
    mkdir -p "$backup_path"

    # Определяем веб-сервер
    local web_server="unknown"
    if [[ -d "$NGINX_DIR" ]] && [[ -f "$NGINX_DIR/docker-compose.yml" ]]; then
        web_server="nginx"
    elif [[ -f "/etc/caddy/Caddyfile" ]]; then
        web_server="caddy"
    fi

    # 1. Backend конфиги
    info "Копирую конфиги backend..."
    cp "$CONFIG_FILE" "${backup_path}/.env" 2>/dev/null || true
    cp "${APP_DIR}/docker-compose.yml" "${backup_path}/docker-compose.yml" 2>/dev/null || true

    # 2. Subscription
    info "Копирую subscription..."
    mkdir -p "${backup_path}/subscription"
    cp "${SUB_DIR}/.env" "${backup_path}/subscription/.env" 2>/dev/null || true
    cp "${SUB_DIR}/docker-compose.yml" "${backup_path}/subscription/docker-compose.yml" 2>/dev/null || true

    # 3. Nginx (SSL + конфиги)
    if [[ -d "$NGINX_DIR" ]]; then
        info "Копирую Nginx (SSL + конфиги)..."
        mkdir -p "${backup_path}/nginx"
        cp "${NGINX_DIR}/nginx.conf" "${backup_path}/nginx/nginx.conf" 2>/dev/null || true
        cp "${NGINX_DIR}/docker-compose.yml" "${backup_path}/nginx/docker-compose.yml" 2>/dev/null || true
        cp "${NGINX_DIR}/fullchain.pem" "${backup_path}/nginx/fullchain.pem" 2>/dev/null || true
        cp "${NGINX_DIR}/privkey.key" "${backup_path}/nginx/privkey.key" 2>/dev/null || true
        cp "${NGINX_DIR}/subdomain_fullchain.pem" "${backup_path}/nginx/subdomain_fullchain.pem" 2>/dev/null || true
        cp "${NGINX_DIR}/subdomain_privkey.key" "${backup_path}/nginx/subdomain_privkey.key" 2>/dev/null || true
    fi

    # 4. Caddy конфиг
    if [[ -f "/etc/caddy/Caddyfile" ]]; then
        info "Копирую Caddy конфиг..."
        mkdir -p "${backup_path}/caddy"
        cp "/etc/caddy/Caddyfile" "${backup_path}/caddy/Caddyfile" 2>/dev/null || true
        if [[ -d "/var/lib/caddy" ]]; then
            cp -r "/var/lib/caddy" "${backup_path}/caddy/data" 2>/dev/null || true
        fi
    fi

    # 5. Метаданные
    echo "$web_server" > "${backup_path}/web_server_type"
    echo "$DOMAIN" > "${backup_path}/domain"
    echo "$SUB_DOMAIN" > "${backup_path}/sub_domain"

    # Создаём архив
    cd "$BACKUP_DIR"
    tar -czf "${backup_name}.tar.gz" "$backup_name"
    rm -rf "$backup_path"

    # Очистка старых бэкапов (оставляем последние 7)
    ls -t "${BACKUP_DIR}"/remnawave_backup_*.tar.gz 2>/dev/null | tail -n +8 | xargs -r rm

    info "Бэкап создан: ${BACKUP_DIR}/${backup_name}.tar.gz"
    echo "${BACKUP_DIR}/${backup_name}.tar.gz"
}

# ===================== ВОССТАНОВЛЕНИЕ =====================
restore_panel() {
    local backup_file="$1"

    if [[ ! -f "$backup_file" ]]; then
        error "Файл бэкапа не найден: $backup_file"
        return 1
    fi

    info "Восстанавливаю из бэкапа..."

    # Останавливаем сервисы
    systemctl stop caddy 2>/dev/null || true
    cd "$NGINX_DIR" 2>/dev/null && docker compose down 2>/dev/null || true
    cd "$SUB_DIR" 2>/dev/null && docker compose down 2>/dev/null || true
    cd "$APP_DIR" 2>/dev/null && docker compose down 2>/dev/null || true

    # Распаковываем
    local temp_dir=$(mktemp -d)
    tar -xzf "$backup_file" -C "$temp_dir"

    local backup_dir=$(find "$temp_dir" -maxdepth 1 -type d -name "remnawave_backup_*" | head -1)
    if [[ -z "$backup_dir" ]]; then
        error "Неверная структура бэкапа"
        rm -rf "$temp_dir"
        return 1
    fi

    # Читаем метаданные
    local backup_domain=""
    local backup_sub_domain=""
    local backup_web_server="nginx"

    [[ -f "${backup_dir}/domain" ]] && backup_domain=$(<"${backup_dir}/domain")
    [[ -f "${backup_dir}/sub_domain" ]] && backup_sub_domain=$(<"${backup_dir}/sub_domain")
    [[ -f "${backup_dir}/web_server_type" ]] && backup_web_server=$(<"${backup_dir}/web_server_type")

    info "Домен в бэкапе: ${backup_domain:-неизвестно}"
    info "Веб-сервер в бэкапе: ${backup_web_server}"

    # Спрашиваем домен
    echo -e "\n${BLUE}=== Восстановление ===${NC}"
    echo "Домен в бэкапе: ${backup_domain:-неизвестно}"
    echo "  1) Оставить домен из бэкапа"
    echo "  2) Указать новый домен"
    read -rp "Выбор [1-2]: " domain_choice < /dev/tty

    local new_domain=""
    local new_sub_domain=""
    local new_email=""

    if [[ "$domain_choice" == "2" ]]; then
        read -rp "Новый домен панели: " new_domain < /dev/tty
        new_domain=$(echo "$new_domain" | tr -d '\r' | sed 's/[^a-zA-Z0-9@._-]//g')
        read -rp "Новый поддомен подписки: " new_sub_domain < /dev/tty
        new_sub_domain=$(echo "$new_sub_domain" | tr -d '\r' | sed 's/[^a-zA-Z0-9@._-]//g')
        read -rp "Email для SSL: " new_email < /dev/tty
        new_email=$(echo "$new_email" | tr -d '\r' | sed 's/[^a-zA-Z0-9@._+-]//g')
    fi

    # Спрашиваем веб-сервер
    echo "Веб-сервер в бэкапе: ${backup_web_server}"
    echo "  1) Оставить ${backup_web_server}"
    echo "  2) Nginx"
    echo "  3) Caddy"
    read -rp "Выбор [1-3]: " ws_choice < /dev/tty

    local target_web_server="$backup_web_server"
    case "$ws_choice" in
        2) target_web_server="nginx" ;;
        3) target_web_server="caddy" ;;
    esac

    # Восстанавливаем файлы
    info "Восстанавливаю файлы..."

    # Backend
    mkdir -p "$APP_DIR"
    [[ -f "${backup_dir}/.env" ]] && cp "${backup_dir}/.env" "${APP_DIR}/.env"
    [[ -f "${backup_dir}/docker-compose.yml" ]] && cp "${backup_dir}/docker-compose.yml" "${APP_DIR}/docker-compose.yml"

    # Subscription
    mkdir -p "$SUB_DIR"
    [[ -f "${backup_dir}/subscription/.env" ]] && cp "${backup_dir}/subscription/.env" "${SUB_DIR}/.env"
    [[ -f "${backup_dir}/subscription/docker-compose.yml" ]] && cp "${backup_dir}/subscription/docker-compose.yml" "${SUB_DIR}/docker-compose.yml"

    # Nginx
    if [[ -d "${backup_dir}/nginx" ]]; then
        mkdir -p "$NGINX_DIR"
        cp -r "${backup_dir}/nginx/"* "$NGINX_DIR/" 2>/dev/null || true
    fi

    # Caddy
    if [[ -d "${backup_dir}/caddy" ]]; then
        mkdir -p /etc/caddy
        [[ -f "${backup_dir}/caddy/Caddyfile" ]] && cp "${backup_dir}/caddy/Caddyfile" /etc/caddy/Caddyfile
        if [[ -d "${backup_dir}/caddy/data" ]]; then
            mkdir -p /var/lib/caddy
            cp -r "${backup_dir}/caddy/data/"* /var/lib/caddy/ 2>/dev/null || true
        fi
    fi

    # Обновляем домен если нужно
    if [[ -n "$new_domain" ]]; then
        info "Обновляю домен: ${backup_domain} → ${new_domain}"

        # Backend .env
        sed -i "s|^FRONT_END_DOMAIN=.*|FRONT_END_DOMAIN=$new_domain|" "${APP_DIR}/.env"
        sed -i "s|^SUB_PUBLIC_DOMAIN=.*|SUB_PUBLIC_DOMAIN=$new_sub_domain|" "${APP_DIR}/.env"

        # Nginx конфиг
        if [[ "$target_web_server" == "nginx" && -f "${NGINX_DIR}/nginx.conf" ]]; then
            sed -i "s|server_name .*|server_name $new_domain;|" "${NGINX_DIR}/nginx.conf"
            sed -i "s|server_name .*|server_name $new_sub_domain;|" "${NGINX_DIR}/nginx.conf"
        fi

        # Caddy конфиг
        if [[ "$target_web_server" == "caddy" ]]; then
            sed -i "s|^${backup_domain}.*|${new_domain}|" /etc/caddy/Caddyfile
            sed -i "s|^${backup_sub_domain}.*|${new_sub_domain}|" /etc/caddy/Caddyfile
        fi

        # Получаем новые SSL
        if [[ -n "$new_email" ]]; then
            info "Получаю новые SSL сертификаты..."
            export PATH="$HOME/.acme.sh:$PATH"
            ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt
            ~/.acme.sh/acme.sh --issue --standalone -d "$new_domain" \
                --key-file "${NGINX_DIR}/privkey.key" \
                --fullchain-file "${NGINX_DIR}/fullchain.pem" || warn "SSL для панели не получен"
            ~/.acme.sh/acme.sh --issue --standalone -d "$new_sub_domain" \
                --key-file "${NGINX_DIR}/subdomain_privkey.key" \
                --fullchain-file "${NGINX_DIR}/subdomain_fullchain.pem" || warn "SSL для подписки не получен"
        fi
    fi

    # Запускаем сервисы
    info "Запускаю сервисы..."
    docker network create remnawave-network 2>/dev/null || true

    cd "$APP_DIR" && docker compose up -d
    cd "$SUB_DIR" && docker compose up -d

    if [[ "$target_web_server" == "nginx" ]]; then
        cd "$NGINX_DIR" && docker compose up -d
    else
        systemctl enable --now caddy
    fi

    rm -rf "$temp_dir"

    echo -e "\n${GREEN}Восстановление завершено!${NC}"
    [[ -n "$new_domain" ]] && echo -e "Новый домен: ${CYAN}https://${new_domain}${NC}"
    echo ""
}

# ===================== МИГРАЦИЯ =====================
migrate_panel() {
    info "Запуск миграции..."

    # Параметры исходного сервера
    read -rp "IP/hostname исходного сервера: " source_server < /dev/tty
    read -rp "SSH пользователь [root]: " source_user < /dev/tty
    source_user="${source_user:-root}"
    read -rp "SSH порт [22]: " source_port < /dev/tty
    source_port="${source_port:-22}"

    # Будет ли меняться домен?
    read -rp "Будет ли изменён домен? (yes/no): " domain_change < /dev/tty

    local new_domain=""
    local new_sub_domain=""
    local new_email=""

    if [[ "$domain_change" == "yes" ]]; then
        read -rp "Новый домен панели: " new_domain < /dev/tty
        new_domain=$(echo "$new_domain" | tr -d '\r' | sed 's/[^a-zA-Z0-9@._-]//g')
        read -rp "Новый поддомен подписки: " new_sub_domain < /dev/tty
        new_sub_domain=$(echo "$new_sub_domain" | tr -d '\r' | sed 's/[^a-zA-Z0-9@._-]//g')
        read -rp "Email для SSL: " new_email < /dev/tty
        new_email=$(echo "$new_email" | tr -d '\r' | sed 's/[^a-zA-Z0-9@._+-]//g')
    fi

    # Целевой веб-сервер
    echo "Выберите веб-сервер на новом сервере:"
    echo "  1) Оставить как на исходном"
    echo "  2) Nginx"
    echo "  3) Caddy"
    read -rp "Выбор [1-3]: " ws_choice < /dev/tty

    local target_web_server="source"
    case "$ws_choice" in
        2) target_web_server="nginx" ;;
        3) target_web_server="caddy" ;;
    esac

    # SSH ключ
    if [[ ! -f ~/.ssh/id_rsa ]]; then
        info "Генерирую SSH ключ..."
        ssh-keygen -t rsa -b 4096 -f ~/.ssh/id_rsa -N "" -q
    fi

    # Тест подключения
    info "Проверяю подключение к ${source_server}..."
    if ! ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no -p "$source_port" "${source_user}@${source_server}" "echo OK" > /dev/null 2>&1; then
        error "Не удалось подключиться к ${source_server}"
        return 1
    fi
    info "Подключение OK"

    # Копируем бэкап
    info "Копирую бэкап с исходного сервера..."
    mkdir -p "$BACKUP_DIR"

    # Пробуем скопировать готовый бэкап
    if ! scp -o StrictHostKeyChecking=no -P "$source_port" \
        "${source_user}@${source_server}:/opt/remnawave/backups/remnawave_backup_*.tar.gz" \
        "$BACKUP_DIR/" 2>/dev/null; then

        warn "Готовый бэкап не найден. Создаю на исходном сервере..."
        ssh -o StrictHostKeyChecking=no -p "$source_port" "${source_user}@${source_server}" \
            "cd /opt/remnawave && \
             BACKUP_NAME=\$(date +%Y%m%d_%H%M%S) && \
             mkdir -p /tmp/\$BACKUP_NAME && \
             cp .env /tmp/\$BACKUP_NAME/ && \
             cp docker-compose.yml /tmp/\$BACKUP_NAME/ && \
             cp -r nginx /tmp/\$BACKUP_NAME/nginx 2>/dev/null || true && \
             cp -r subscription /tmp/\$BACKUP_NAME/subscription 2>/dev/null || true && \
             cp -r /etc/caddy/Caddyfile /tmp/\$BACKUP_NAME/caddy/Caddyfile 2>/dev/null || true && \
             cp /etc/caddy/Caddyfile /tmp/\$BACKUP_NAME/caddy/Caddyfile 2>/dev/null || true && \
             echo nginx > /tmp/\$BACKUP_NAME/web_server_type && \
             tar -czf /tmp/remnawave_migration.tar.gz -C /tmp \$BACKUP_NAME && \
             rm -rf /tmp/\$BACKUP_NAME"

        scp -o StrictHostKeyChecking=no -P "$source_port" \
            "${source_user}@${source_server}:/tmp/remnawave_migration.tar.gz" \
            "$BACKUP_DIR/" 2>/dev/null || {
            error "Не удалось скопировать бэкап"
            return 1
        }
    fi

    # Находим последний бэкап
    local latest_backup=$(ls -t "${BACKUP_DIR}"/remnawave_backup_*.tar.gz 2>/dev/null | head -1)
    if [[ -z "$latest_backup" ]]; then
        error "Бэкап не найден"
        return 1
    fi

    info "Бэкап: $latest_backup"

    # Восстанавливаем с параметрами
    if [[ -n "$new_domain" ]]; then
        # Временно подменяем функцию restore_panel для передачи параметров
        WEB_SERVER="$target_web_server"
        DOMAIN="$new_domain"
        SUB_DOMAIN="$new_sub_domain"
        EMAIL="$new_email"
    fi

    # Восстанавливаем
    if [[ "$target_web_server" != "source" ]]; then
        WEB_SERVER="$target_web_server"
    fi

    restore_panel "$latest_backup"

    echo -e "\n${GREEN}Миграция завершена!${NC}"
    if [[ -n "$new_domain" ]]; then
        echo -e "Новый домен: ${CYAN}https://${new_domain}${NC}"
        echo -e "${YELLOW}Убедись, что DNS записи указывают на IP нового сервера${NC}"
    fi
    echo ""
}

# ===================== ОБНОВЛЕНИЕ =====================
update_panel() {
    info "Проверяю обновления..."

    cd "$APP_DIR"

    # Останавливаем
    docker compose down
    cd "$SUB_DIR" && docker compose down 2>/dev/null || true

    # Бэкап перед обновлением
    backup_panel

    # Обновляем образы
    info "Скачиваю новые образы..."
    cd "$APP_DIR" && docker compose pull
    cd "$SUB_DIR" && docker compose pull 2>/dev/null || true

    # Запускаем
    cd "$APP_DIR" && docker compose up -d
    cd "$SUB_DIR" && docker compose up -d

    info "Обновление завершено"
}

# ===================== УДАЛЕНИЕ =====================
uninstall_panel() {
    warn "Это удалит RemnaWave и все данные!"
    read -rp "Введите 'yes' для подтверждения: " confirm < /dev/tty

    if [[ "$confirm" != "yes" ]]; then
        info "Отменено"
        return
    fi

    # Останавливаем
    systemctl stop caddy 2>/dev/null || true
    systemctl disable caddy 2>/dev/null || true

    cd "$NGINX_DIR" 2>/dev/null && docker compose down 2>/dev/null || true
    cd "$SUB_DIR" 2>/dev/null && docker compose down 2>/dev/null || true
    cd "$APP_DIR" 2>/dev/null && docker compose down 2>/dev/null || true

    # Удаляем
    rm -rf "$APP_DIR"
    rm -f /etc/caddy/Caddyfile

    # Удаляем контейнеры и образы
    docker container prune -f 2>/dev/null || true
    docker image prune -f 2>/dev/null || true

    info "RemnaWave удалён"
}

# ===================== СТАТУС =====================
show_status() {
    echo -e "${CYAN}═══════════════════════════════════════${NC}"
    echo -e "${CYAN}   Статус RemnaWave Panel${NC}"
    echo -e "${CYAN}═══════════════════════════════════════${NC}"

    # Backend
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "remnawave$"; then
        echo -e "Backend:    ${GREEN}Запущен${NC}"
    else
        echo -e "Backend:    ${RED}Остановлен${NC}"
    fi

    # Subscription
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "remnawave-subscription"; then
        echo -e "Subscription: ${GREEN}Запущен${NC}"
    else
        echo -e "Subscription: ${RED}Остановлен${NC}"
    fi

    # Nginx/Caddy
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "remnawave-nginx"; then
        echo -e "Nginx:      ${GREEN}Запущен${NC}"
    elif systemctl is-active --quiet caddy 2>/dev/null; then
        echo -e "Caddy:      ${GREEN}Запущен${NC}"
    else
        echo -e "Веб-сервер: ${RED}Остановлен${NC}"
    fi

    # Домен
    if [[ -f "$CONFIG_FILE" ]]; then
        local domain=$(grep "^FRONT_END_DOMAIN=" "$CONFIG_FILE" | cut -d= -f2)
        echo -e "Домен:      ${domain:-не настроен}"
    fi

    # Бэкапы
    local backup_count=$(ls -1 "${BACKUP_DIR}"/remnawave_backup_*.tar.gz 2>/dev/null | wc -l)
    echo -e "Бэкапы:     $backup_count"

    echo -e "${CYAN}═══════════════════════════════════════${NC}"
}

# ===================== ГЛАВНОЕ МЕНЮ =====================
show_menu() {
    clear
    echo -e "${BLUE}${BOLD}"
    echo "  ____                                                  "
    echo " |  _ \ ___ _ __ ___  _ __   __ ___      ____ ___   _____ "
    echo " | |_) / _ \ '_ \ _ \| '_ \ / _\` \ \ /\ / / _\` \ \ / / _ \\"
    echo " |  _ <  __/ | | | | | | | | (_| |\ V  V / (_| |\ V /  __/"
    echo " |_| \_\___|_| |_| |_|_| |_|\__,_| \_/\_/ \__,_| \_/ \___|"
    echo ""
    echo -e "      ${YELLOW}v3.0.0 — Docker Compose Edition${NC}"
    echo -e "${BLUE}======================================================${NC}\n"

    if [[ -f "$CONFIG_FILE" ]]; then
        show_status
    fi

    echo -e "${BLUE}Главное меню:${NC}"
    echo "  1) Чистая установка"
    echo "  2) Миграция (с другого сервера)"
    echo "  3) Создать бэкап"
    echo "  4) Восстановить из бэкапа"
    echo "  5) Обновить панель"
    echo "  6) Удалить панель"
    echo "  7) Показать статус"
    echo "  8) Выход"
    echo ""
    read -rp "Выберите опцию [1-8]: " choice < /dev/tty

    case $choice in
        1) full_install ;;
        2)
            migrate_panel
            echo -e "\n${GREEN}Нажмите Enter для продолжения...${NC}"
            read < /dev/tty
            show_menu
            ;;
        3)
            backup_panel
            echo -e "\n${GREEN}Нажмите Enter для продолжения...${NC}"
            read < /dev/tty
            show_menu
            ;;
        4)
            echo "Доступные бэкапы:"
            ls -lh "${BACKUP_DIR}"/remnawave_backup_*.tar.gz 2>/dev/null || echo "Бэкапы не найдены"
            echo ""
            read -rp "Путь к бэкапу: " backup_file < /dev/tty
            restore_panel "$backup_file"
            echo -e "\n${GREEN}Нажмите Enter для продолжения...${NC}"
            read < /dev/tty
            show_menu
            ;;
        5)
            update_panel
            echo -e "\n${GREEN}Нажмите Enter для продолжения...${NC}"
            read < /dev/tty
            show_menu
            ;;
        6)
            uninstall_panel
            echo -e "\n${GREEN}Нажмите Enter для продолжения...${NC}"
            read < /dev/tty
            show_menu
            ;;
        7)
            show_status
            echo -e "\n${GREEN}Нажмите Enter для продолжения...${NC}"
            read < /dev/tty
            show_menu
            ;;
        8)
            info "Выход"
            exit 0
            ;;
        *)
            warn "Неверный выбор"
            sleep 1
            show_menu
            ;;
    esac
}

# ===================== ТОЧКА ВХОДА =====================
cleanup() {
    warn "Установка прервана"
    exit 1
}

trap cleanup SIGINT SIGTERM

main() {
    check_root
    check_terminal

    mkdir -p "$(dirname "$LOG_FILE")"
    > "$LOG_FILE"

    info "RemnaWave Installation Script v3.0.0"
    info "Логи: ${LOG_FILE}"

    show_menu
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
