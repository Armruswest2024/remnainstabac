#!/bin/bash

# RemnaWave Panel Installation Script
# Version: 1.1.0
# Author: RemnaWave Team

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Global variables
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="/var/log/remnawave_install.log"
APP_DIR="/opt/remnawave"
CONFIG_FILE="${APP_DIR}/.env"
BACKUP_DIR="/opt/remnawave/backups"
PG_VERSION=""
DOMAIN=""
EMAIL=""
WEB_SERVER=""
INSTALL_MODE=""
DB_PASSWORD=""
ADMIN_USERNAME=""
ADMIN_PASSWORD=""
JWT_SECRET=""
APP_VERSION="latest"
GITHUB_REPO="remnawave/remnawave"

# Logging function
log() {
    local level="$1"
    local message="$2"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo -e "${timestamp} [${level}] ${message}" | tee -a "$LOG_FILE"
}

info() { log "INFO" "$1"; echo -e "${GREEN}[INFO]${NC} $1"; }
warn() { log "WARN" "$1"; echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { log "ERROR" "$1"; echo -e "${RED}[ERROR]${NC} $1"; }

# Check if running as root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "This script must be run as root"
        exit 1
    fi
}

# Check system requirements
check_requirements() {
    info "Checking system requirements..."
    
    # Check OS
    if [[ ! -f /etc/debian_version ]]; then
        error "This script only supports Debian-based systems"
        exit 1
    fi
    
    # Check RAM (minimum 2GB)
    local ram=$(free -m | awk '/^Mem:/{print $2}')
    if [[ $ram -lt 2048 ]]; then
        warn "System has less than 2GB RAM. Installation may be unstable."
    fi
    
    # Check disk space (minimum 10GB)
    local disk=$(df -BG / | awk 'NR==2 {print $4}' | sed 's/G//')
    if [[ $disk -lt 10 ]]; then
        error "Insufficient disk space. Minimum 10GB required."
        exit 1
    fi
    
    # Check required ports
    for port in 80 443; do
        if ss -tlnp | grep -q ":$port "; then
            warn "Port $port is already in use"
        fi
    done
    
    info "System requirements check completed"
}

# Generate random string
generate_secret() {
    openssl rand -base64 32 | tr -d '\n'
}

# Get user input with validation
get_input() {
    local prompt="$1"
    local default="$2"
    local validation="$3"
    local result
    
    while true; do
        if [[ -n "$default" ]]; then
            read -rp "${prompt} [${default}]: " result
            result="${result:-$default}"
        else
            read -rp "${prompt}: " result
        fi
        
        if [[ -z "$validation" ]] || [[ "$result" =~ $validation ]]; then
            echo "$result"
            return 0
        else
            warn "Invalid input. Please try again."
        fi
    done
}

# Install system dependencies
install_dependencies() {
    info "Installing system dependencies..."
    
    apt-get update -qq
    apt-get install -y -qq \
        curl wget git unzip zip tar \
        postgresql postgresql-contrib \
        nginx certbot python3-certbot-nginx \
        jq systemd supervisor \
        ca-certificates gnupg lsb-release > /dev/null 2>&1
    
    # Detect PostgreSQL version
    PG_VERSION=$(psql --version | grep -oP '\d+' | head -1)
    
    info "Dependencies installed successfully (PostgreSQL $PG_VERSION)"
}

# Configure PostgreSQL
setup_postgresql() {
    info "Configuring PostgreSQL..."
    
    # Create log directory for PostgreSQL
    mkdir -p /var/log/postgresql
    
    # Start PostgreSQL
    systemctl enable --now postgresql
    
    # Wait for PostgreSQL to be ready
    local max_wait=30
    local waited=0
    while ! pg_isready -q && [ $waited -lt $max_wait ]; do
        sleep 1
        ((waited++))
    done
    
    if ! pg_isready -q; then
        error "PostgreSQL failed to start"
        return 1
    fi
    
    # Generate database password if not set
    if [[ -z "$DB_PASSWORD" ]]; then
        DB_PASSWORD=$(generate_secret)
    fi
    
    # Create database and user with proper error handling
    if ! sudo -u postgres psql -c "CREATE DATABASE remnawave;" 2>&1 | tee -a "$LOG_FILE"; then
        warn "Database creation may have failed (might already exist)"
    fi
    if ! sudo -u postgres psql -c "CREATE USER remnawave WITH PASSWORD '${DB_PASSWORD}';" 2>&1 | tee -a "$LOG_FILE"; then
        warn "User creation may have failed (might already exist)"
    fi
    sudo -u postgres psql -c "GRANT ALL PRIVILEGES ON DATABASE remnawave TO remnawave;" || {
        error "Failed to grant privileges"
        return 1
    }
    sudo -u postgres psql -c "ALTER DATABASE remnawave OWNER TO remnawave;" || {
        error "Failed to set database owner"
        return 1
    }
    
    # Configure pg_hba.conf for local connections
    local pg_hba_file=""
    for conf in /etc/postgresql/*/main/pg_hba.conf; do
        if [[ -f "$conf" ]]; then
            pg_hba_file="$conf"
            break
        fi
    done
    
    if [[ -n "$pg_hba_file" ]] && ! grep -q "remnawave" "$pg_hba_file"; then
        echo "local   remnawave   remnawave   md5" >> "$pg_hba_file"
        echo "host    remnawave   remnawave   127.0.0.1/32   md5" >> "$pg_hba_file"
        systemctl reload postgresql
    fi
    
    info "PostgreSQL configured successfully"
}

# Setup web server (Nginx or Caddy)
setup_webserver() {
    if [[ "$WEB_SERVER" == "nginx" ]]; then
        setup_nginx_docker
    else
        setup_caddy
    fi
}

# Setup Nginx with Docker (compatible with autoremna.sh structure)
setup_nginx_docker() {
    info "Configuring Nginx with Docker..."
    
    # Create directory structure
    mkdir -p /opt/remnawave/nginx
    
    # Install acme.sh for SSL certificates
    info "Installing acme.sh for SSL certificates..."
    curl https://get.acme.sh | sh -s email="$EMAIL" > /dev/null 2>&1
    source ~/.bashrc
    export PATH="$HOME/.acme.sh:$PATH"
    
    # Set default CA to Let's Encrypt
    ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt
    
    # Generate SSL certificate for main domain
    info "Generating SSL certificate for $DOMAIN..."
    ~/.acme.sh/acme.sh --issue --standalone -d "$DOMAIN" \
        --key-file /opt/remnawave/nginx/privkey.key \
        --fullchain-file /opt/remnawave/nginx/fullchain.pem \
        > /dev/null 2>&1
    
    # Generate SSL certificate for subscription subdomain if provided
    if [[ -n "$SUB_DOMAIN" ]]; then
        info "Generating SSL certificate for $SUB_DOMAIN..."
        ~/.acme.sh/acme.sh --issue --standalone -d "$SUB_DOMAIN" \
            --key-file /opt/remnawave/nginx/subdomain_privkey.key \
            --fullchain-file /opt/remnawave/nginx/subdomain_fullchain.pem \
            > /dev/null 2>&1
    fi
    
    # Verify certificates were created
    if [[ ! -f /opt/remnawave/nginx/fullchain.pem ]] || [[ ! -f /opt/remnawave/nginx/privkey.key ]]; then
        error "Failed to generate SSL certificates"
        return 1
    fi
    
    # Create nginx.conf
    create_nginx_config
    
    # Create docker-compose.yml for Nginx
    create_nginx_docker_compose
    
    # Start Nginx container
    cd /opt/remnawave/nginx
    if command -v docker &> /dev/null && docker compose version &> /dev/null; then
        docker compose up -d
    elif command -v docker-compose &> /dev/null; then
        docker-compose up -d
    else
        error "Docker or docker-compose not found"
        return 1
    fi
    
    info "Nginx configured successfully with Docker"
}

# Create Nginx configuration file
create_nginx_config() {
    local sub_domain_config=""
    if [[ -n "$SUB_DOMAIN" ]]; then
        sub_domain_config="
server {
    server_name $SUB_DOMAIN;

    listen 443 ssl;
    listen [::]:443 ssl;
    http2 on;

    location / {
        proxy_http_version 1.1;
        proxy_pass http://remnawave-subscription-page:3010;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Forwarded-Host \$host;
        proxy_set_header X-Forwarded-Port \$server_port;

        proxy_send_timeout 60s;
        proxy_read_timeout 60s;
    }

    ssl_protocols          TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384:DHE-RSA-CHACHA20-POLY1305;

    ssl_session_timeout 1d;
    ssl_session_cache shared:MozSSL:10m;
    ssl_session_tickets    off;
    ssl_certificate "/opt/remnawave/nginx/subdomain_fullchain.pem";
    ssl_certificate_key "/opt/remnawave/nginx/subdomain_privkey.key";
    ssl_trusted_certificate "/opt/remnawave/nginx/subdomain_fullchain.pem";

    ssl_stapling           on;
    ssl_stapling_verify    on;
    resolver               1.1.1.1 1.0.0.1 8.8.8.8 8.8.4.4 208.67.222.222 208.67.220.220 valid=60s;
    resolver_timeout       2s;

    gzip on;
    gzip_vary on;
    gzip_proxied any;
    gzip_comp_level 6;
    gzip_buffers 16 8k;
    gzip_http_version 1.1;
    gzip_min_length 256;
    gzip_types
        application/atom+xml
        application/geo+json
        application/javascript
        application/x-javascript
        application/json
        application/ld+json
        application/manifest+json
        application/rdf+xml
        application/rss+xml
        application/xhtml+xml
        application/xml
        font/eot
        font/otf
        font/ttf
        image/svg+xml
        text/css
        text/javascript
        text/plain
        text/xml;
}"
    fi
    
    cat > /opt/remnawave/nginx/nginx.conf << EOF
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

    ssl_protocols          TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384:DHE-RSA-CHACHA20-POLY1305;

    ssl_session_timeout 1d;
    ssl_session_cache shared:MozSSL:10m;
    ssl_session_tickets    off;
    ssl_certificate "/opt/remnawave/nginx/fullchain.pem";
    ssl_certificate_key "/opt/remnawave/nginx/privkey.key";
    ssl_trusted_certificate "/opt/remnawave/nginx/fullchain.pem";

    ssl_stapling           on;
    ssl_stapling_verify    on;
    resolver               1.1.1.1 1.0.0.1 8.8.8.8 8.8.4.4 208.67.222.222 208.67.220.220 valid=60s;
    resolver_timeout       2s;

    gzip on;
    gzip_vary on;
    gzip_proxied any;
    gzip_comp_level 6;
    gzip_buffers 16 8k;
    gzip_http_version 1.1;
    gzip_min_length 256;
    gzip_types
        application/atom+xml
        application/geo+json
        application/javascript
        application/x-javascript
        application/json
        application/ld+json
        application/manifest+json
        application/rdf+xml
        application/rss+xml
        application/xhtml+xml
        application/xml
        font/eot
        font/otf
        font/ttf
        image/svg+xml
        text/css
        text/javascript
        text/plain
        text/xml;
}$sub_domain_config

server {
    server_name _;
    listen 443 ssl default_server;
    listen [::]:443 ssl default_server;
    ssl_reject_handshake on;
}
EOF
}

# Create docker-compose.yml for Nginx
create_nginx_docker_compose() {
    local volumes="
            - ./nginx.conf:/etc/nginx/conf.d/default.conf:ro
            - ./fullchain.pem:/opt/remnawave/nginx/fullchain.pem:ro
            - ./privkey.key:/opt/remnawave/nginx/privkey.key:ro"
    
    if [[ -n "$SUB_DOMAIN" ]] && [[ -f /opt/remnawave/nginx/subdomain_fullchain.pem ]]; then
        volumes="$volumes
            - ./subdomain_fullchain.pem:/opt/remnawave/nginx/subdomain_fullchain.pem:ro
            - ./subdomain_privkey.key:/opt/remnawave/nginx/subdomain_privkey.key:ro"
    fi
    
    cat > /opt/remnawave/nginx/docker-compose.yml << EOF
services:
    remnawave-nginx:
        image: nginx:1.28
        container_name: remnawave-nginx
        hostname: remnawave-nginx
        volumes:$volumes
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
}

# Setup Caddy
setup_caddy() {
    info "Configuring Caddy..."
    
    # Install Caddy
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' > /etc/apt/sources.list.d/caddy-stable.list
    apt-get update -qq
    apt-get install -y -qq caddy > /dev/null 2>&1
    
    # Create Caddyfile
    cat > /etc/caddy/Caddyfile << EOF
${DOMAIN}, www.${DOMAIN} {
    reverse_proxy 127.0.0.1:3000
    
    # Security headers
    header {
        X-Frame-Options "SAMEORIGIN"
        X-Content-Type-Options "nosniff"
        X-XSS-Protection "1; mode=block"
    }
    
    # Static files
    handle_path /static/* {
        root * /opt/remnawave/public
        file_server
    }
}
EOF
    
    # Start Caddy
    systemctl enable --now caddy
    
    info "Caddy configured successfully with automatic SSL"
}

# Install RemnaWave application
install_application() {
    info "Installing RemnaWave application..."
    
    # Create directories
    mkdir -p /opt/remnawave /var/log/remnawave "$BACKUP_DIR" /opt/remnawave/scripts
    
    # Download latest release from GitHub
    info "Downloading RemnaWave application..."
    local download_url="https://github.com/${GITHUB_REPO}/releases/${APP_VERSION}/download/remnawave.tar.gz"
    
    if curl -sfL "$download_url" -o /tmp/remnawave.tar.gz 2>/dev/null; then
        tar xzf /tmp/remnawave.tar.gz -C /opt/remnawave --strip-components=1
        rm -f /tmp/remnawave.tar.gz
        info "Application downloaded and extracted"
    else
        warn "Could not download from GitHub. Creating placeholder structure."
        # Create placeholder structure for testing
        mkdir -p /opt/remnawave/bin /opt/remnawave/public /opt/remnawave/logs
        cat > /opt/remnawave/bin/remnawave << 'PLACEHOLDER'
#!/bin/bash
case "$1" in
    start) echo "RemnaWave started (placeholder)" ;;
    stop) echo "RemnaWave stopped (placeholder)" ;;
    migrate) echo "Migrations completed (placeholder)" ;;
    *) echo "Usage: remnawave {start|stop|migrate}" ;;
esac
PLACEHOLDER
        chmod +x /opt/remnawave/bin/remnawave
    fi
    
    # Create environment file
    cat > "$CONFIG_FILE" << EOF
# RemnaWave Configuration
NODE_ENV=production
PORT=3000
DATABASE_URL=postgresql://remnawave:${DB_PASSWORD}@localhost:5432/remnawave
JWT_SECRET=${JWT_SECRET}
ADMIN_USERNAME=${ADMIN_USERNAME}
ADMIN_PASSWORD=${ADMIN_PASSWORD}
DOMAIN=${DOMAIN}
WEB_SERVER=${WEB_SERVER}
EOF
    
    chmod 600 "$CONFIG_FILE"
    
    # Create backup script
    create_backup_script
    
    info "Application installed successfully"
}

# Create backup script
create_backup_script() {
    info "Creating backup script..."
    
    cat > /opt/remnawave/scripts/backup.sh << 'BACKUP_SCRIPT'
#!/bin/bash
set -e

APP_DIR="/opt/remnawave"
BACKUP_DIR="/opt/remnawave/backups"
CONFIG_FILE="${APP_DIR}/.env"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_NAME="remnawave_backup_${TIMESTAMP}"
BACKUP_PATH="${BACKUP_DIR}/${BACKUP_NAME}"

# Load config
if [[ -f "$CONFIG_FILE" ]]; then
    source "$CONFIG_FILE"
fi

mkdir -p "$BACKUP_PATH"

echo "Starting backup..."

# Backup database
echo "Backing up database..."
PGPASSWORD="${DB_PASSWORD}" pg_dump -U remnawave -h localhost remnawave > "${BACKUP_PATH}/database.sql"

# Backup configuration
echo "Backing up configuration..."
cp "$CONFIG_FILE" "${BACKUP_PATH}/config.env" 2>/dev/null || true
cp -r "${APP_DIR}" "${BACKUP_PATH}/application" 2>/dev/null || true

# Create archive
cd "$BACKUP_DIR"
tar -czf "${BACKUP_NAME}.tar.gz" "$BACKUP_NAME"
rm -rf "$BACKUP_PATH"

# Cleanup old backups (keep last 7)
ls -t "${BACKUP_DIR}"/remnawave_backup_*.tar.gz | tail -n +8 | xargs -r rm

echo "Backup created: ${BACKUP_DIR}/${BACKUP_NAME}.tar.gz"
echo "${BACKUP_DIR}/${BACKUP_NAME}.tar.gz"
BACKUP_SCRIPT
    
    chmod +x /opt/remnawave/scripts/backup.sh
    
    # Setup cron job for daily backups
    if ! crontab -l 2>/dev/null | grep -q "remnawave.*backup"; then
        (crontab -l 2>/dev/null; echo "0 3 * * * /opt/remnawave/scripts/backup.sh >> /var/log/remnawave_backup.log 2>&1") | crontab -
        info "Daily backup cron job configured"
    fi
}

# Create systemd service
setup_service() {
    info "Creating systemd service..."
    
    cat > /etc/systemd/system/remnawave.service << EOF
[Unit]
Description=RemnaWave Panel
After=network.target postgresql.service
Requires=postgresql.service

[Service]
Type=simple
User=root
WorkingDirectory=/opt/remnawave
EnvironmentFile=${CONFIG_FILE}
ExecStart=/opt/remnawave/bin/remnawave start
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=5s

# Security hardening (commented out to prevent conflicts with application)
# NoNewPrivileges=true
# ProtectSystem=strict
# ProtectHome=true
ReadWritePaths=/opt/remnawave /var/log/remnawave

[Install]
WantedBy=multi-user.target
EOF
    
    systemctl daemon-reload
    systemctl enable --now remnawave
    
    info "Systemd service created and started"
}

# Backup panel data
backup_panel() {
    info "Creating panel backup..."
    
    local backup_name="remnawave_backup_$(date +%Y%m%d_%H%M%S)"
    local backup_path="${BACKUP_DIR}/${backup_name}"
    
    mkdir -p "$backup_path"
    
    # Определяем текущий веб-сервер по наличию директорий и контейнеров
    local current_web=""
    if [[ -d "/opt/remnawave/caddy" ]]; then
        current_web="caddy"
    elif [[ -d "/opt/remnawave/nginx" ]]; then
        current_web="nginx"
    else
        # Фолбэк: проверяем запущенные контейнеры
        if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "caddy"; then
            current_web="caddy"
        elif docker ps --format '{{.Names}}' 2>/dev/null | grep -q "nginx"; then
            current_web="nginx"
        fi
    fi

    if [[ -z "$current_web" ]]; then
        warn "Не удалось определить тип веб-сервера. Бэкап может быть неполным."
        current_web="unknown"
    fi

    info "Обнаружен веб-сервер: $current_web"
    
    # Сохраняем тип веб-сервера в метаданных
    echo "$current_web" > "${backup_path}/web_server_type"

    # Backup database
    info "Backing up database..."
    if PGPASSWORD="$DB_PASSWORD" pg_dump -U remnawave -h localhost remnawave > "${backup_path}/database.sql" 2>/dev/null; then
        info "Database backup completed"
    else
        warn "Database backup failed or database is not accessible"
    fi
    
    # Backup configuration
    info "Backing up configuration..."
    cp "$CONFIG_FILE" "${backup_path}/config.env" 2>/dev/null || true
    cp -r "${APP_DIR}/data" "${backup_path}/data" 2>/dev/null || true
    cp -r "${APP_DIR}/db" "${backup_path}/db" 2>/dev/null || true
    cp "${APP_DIR}/docker-compose.yml" "${backup_path}/docker-compose.yml" 2>/dev/null || true
    cp "${APP_DIR}/.env" "${backup_path}/app_env" 2>/dev/null || true
    
    # Backup web server configs based on detected type
    if [[ "$current_web" == "nginx" ]]; then
        if [[ -d "/opt/remnawave/nginx" ]]; then
            info "Backing up Nginx SSL certificates and configuration..."
            cp -r /opt/remnawave/nginx "${backup_path}/nginx" 2>/dev/null || true
        fi
    elif [[ "$current_web" == "caddy" ]]; then
        if [[ -d "/opt/remnawave/caddy" ]]; then
            info "Backing up Caddy configuration and data..."
            cp -r /opt/remnawave/caddy "${backup_path}/caddy" 2>/dev/null || true
        fi
    else
        # Если неизвестно, копируем обе директории если они существуют
        if [[ -d "/opt/remnawave/nginx" ]]; then
            cp -r /opt/remnawave/nginx "${backup_path}/nginx" 2>/dev/null || true
        fi
        if [[ -d "/opt/remnawave/caddy" ]]; then
            cp -r /opt/remnawave/caddy "${backup_path}/caddy" 2>/dev/null || true
        fi
    fi
    
    # Create archive
    tar -czf "${backup_path}.tar.gz" -C "$BACKUP_DIR" "$backup_name"
    rm -rf "$backup_path"
    
    # Cleanup old backups (keep last 7)
    ls -t "${BACKUP_DIR}"/remnawave_backup_*.tar.gz 2>/dev/null | tail -n +8 | xargs -r rm
    
    info "Backup created: ${backup_path}.tar.gz"
    echo "${backup_path}.tar.gz"
}

# Convert Nginx config to Caddyfile
convert_nginx_to_caddy() {
    local nginx_conf="$1"
    local caddyfile="/opt/remnawave/caddy/Caddyfile"
    
    info "Converting Nginx configuration to Caddyfile..."
    
    # Extract domains from nginx config
    local domains=$(grep -oP 'server_name\s+\K[^;]+' "$nginx_conf" 2>/dev/null | tr -d ' ')
    
    if [[ -z "$domains" ]]; then
        warn "Could not extract domains from Nginx config, using default"
        domains="$DOMAIN"
    fi
    
    # Create Caddyfile
    cat > "$caddyfile" << EOF
$(echo $domains | tr ' ' '\n' | while read domain; do
    echo "$domain {"
    echo "    reverse_proxy remnawave:3000"
    echo "    tls {"
    echo "        cert /opt/remnawave/nginx/fullchain.pem"
    echo "        key /opt/remnawave/nginx/privkey.key"
    echo "    }"
    echo "}"
    echo ""
done)
EOF
    
    # Check for subscription page subdomain
    if grep -q "sub" "$nginx_conf" 2>/dev/null; then
        local subdomain=$(grep -oP 'server_name\s+\Ksub[^;]+' "$nginx_conf" 2>/dev/null | head -1 | tr -d ' ')
        if [[ -n "$subdomain" ]]; then
            cat >> "$caddyfile" << EOF
$subdomain {
    reverse_proxy remnawave-subscription-page:3010
    tls {
        cert /opt/remnawave/nginx/subdomain_fullchain.pem
        key /opt/remnawave/nginx/subdomain_privkey.key
    }
}
EOF
        fi
    fi
    
    info "Caddyfile created from Nginx config"
}

# Convert Caddyfile to Nginx config
convert_caddy_to_nginx() {
    local caddyfile="$1"
    
    info "Converting Caddyfile to Nginx configuration..."
    
    # Extract domains from Caddyfile
    local domains=$(grep -oP '^[a-zA-Z0-9.-]+\s*\{' "$caddyfile" 2>/dev/null | sed 's/{//' | tr -d ' ')
    
    if [[ -z "$domains" ]]; then
        domains="$DOMAIN"
    fi
    
    # Create nginx.conf with proper paths
    create_nginx_config
    
    # Copy SSL certificates from Caddy data directory if they exist
    if [[ -d "/opt/remnawave/caddy/data" ]]; then
        local cert_count=$(find /opt/remnawave/caddy/data -name "*.pem" 2>/dev/null | wc -l)
        if [[ $cert_count -gt 0 ]]; then
            info "Copying SSL certificates from Caddy data directory..."
            mkdir -p /opt/remnawave/nginx
            # Try to find and copy certificates
            find /opt/remnawave/caddy/data -name "*.pem" -exec cp {} /opt/remnawave/nginx/ \; 2>/dev/null || true
            find /opt/remnawave/caddy/data -name "*.key" -exec cp {} /opt/remnawave/nginx/ \; 2>/dev/null || true
        fi
    fi
    
    info "Nginx configuration created from Caddy setup"
}

# Handle web server conversion during migration
handle_webserver_conversion() {
    local source_web_server="$1"
    local target_web_server="$2"
    
    if [[ "$source_web_server" == "$target_web_server" ]]; then
        info "Web server type unchanged (${source_web_server}), skipping conversion"
        return 0
    fi
    
    info "Converting from ${source_web_server} to ${target_web_server}..."
    
    if [[ "$source_web_server" == "nginx" ]] && [[ "$target_web_server" == "caddy" ]]; then
        # Backup old nginx config
        if [[ -f /opt/remnawave/nginx/nginx.conf ]]; then
            cp /opt/remnawave/nginx/nginx.conf /opt/remnawave/nginx/nginx.conf.backup.$(date +%Y%m%d%H%M%S)
        fi
        
        # Convert nginx to caddy
        convert_nginx_to_caddy "/opt/remnawave/nginx/nginx.conf"
        
        # Stop nginx containers
        cd /opt/remnawave/nginx 2>/dev/null
        docker compose down 2>/dev/null || docker-compose down 2>/dev/null || true
        cd - > /dev/null
        
        info "Nginx converted to Caddy successfully"
        
    elif [[ "$source_web_server" == "caddy" ]] && [[ "$target_web_server" == "nginx" ]]; then
        # Backup old caddyfile
        if [[ -f /opt/remnawave/caddy/Caddyfile ]]; then
            cp /opt/remnawave/caddy/Caddyfile /opt/remnawave/caddy/Caddyfile.backup.$(date +%Y%m%d%H%M%S)
        fi
        
        # Convert caddy to nginx
        convert_caddy_to_nginx "/opt/remnawave/caddy/Caddyfile"
        
        # Stop caddy
        systemctl stop caddy 2>/dev/null || true
        
        info "Caddy converted to Nginx successfully"
    fi
}

# Restore panel from backup
restore_panel() {
    local backup_file="$1"
    local skip_db_password="${2:-false}"
    
    if [[ ! -f "$backup_file" ]]; then
        error "Backup file not found: $backup_file"
        return 1
    fi
    
    info "Restoring panel from backup..."
    
    # Stop services
    systemctl stop remnawave 2>/dev/null || true
    
    # Extract backup
    local temp_dir=$(mktemp -d)
    tar -xzf "$backup_file" -C "$temp_dir"
    
    # Find the backup directory inside temp
    local backup_content_dir=$(find "$temp_dir" -maxdepth 1 -type d -name "remnawave_backup_*" | head -1)
    
    if [[ -z "$backup_content_dir" ]]; then
        error "Invalid backup structure"
        rm -rf "$temp_dir"
        return 1
    fi
    
    # Load old config to get DB password and web server type
    local old_config="${backup_content_dir}/config.env"
    local restore_db_password=""
    local source_web_server="nginx"
    
    # Сначала пытаемся прочитать тип веб-сервера из файла метаданных
    if [[ -f "${backup_content_dir}/web_server_type" ]]; then
        source_web_server=$(cat "${backup_content_dir}/web_server_type")
        info "Веб-сервер в бэкапе (из метаданных): $source_web_server"
    elif [[ -f "$old_config" ]]; then
        source "$old_config" 2>/dev/null || true
        restore_db_password="$DB_PASSWORD"
        source_web_server="${WEB_SERVER:-nginx}"
        info "Веб-сервер в бэкапе (из конфига): $source_web_server"
    else
        # Пытаемся определить по наличию директорий в бэкапе
        if [[ -d "${backup_content_dir}/caddy" ]]; then
            source_web_server="caddy"
        elif [[ -d "${backup_content_dir}/nginx" ]]; then
            source_web_server="nginx"
        fi
        info "Веб-сервер в бэкапе (определен автоматически): $source_web_server"
    fi
    
    # If we couldn't get password from backup, use current or generate new
    if [[ -z "$restore_db_password" ]]; then
        if [[ -n "$DB_PASSWORD" ]]; then
            restore_db_password="$DB_PASSWORD"
        else
            restore_db_password=$(generate_secret)
        fi
    fi
    
    # Restore database - terminate active connections first
    info "Restoring database..."
    sudo -u postgres psql -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = 'remnawave' AND pid <> pg_backend_pid();" 2>/dev/null || true
    sudo -u postgres psql -c "DROP DATABASE IF EXISTS remnawave;" 2>/dev/null || true
    sudo -u postgres psql -c "DROP USER IF EXISTS remnawave;" 2>/dev/null || true
    sudo -u postgres psql -c "CREATE DATABASE remnawave;" 2>/dev/null || true
    sudo -u postgres psql -c "CREATE USER remnawave WITH PASSWORD '${restore_db_password}';" 2>/dev/null || true
    sudo -u postgres psql -c "GRANT ALL PRIVILEGES ON DATABASE remnawave TO remnawave;" 2>/dev/null || true
    sudo -u postgres psql -c "ALTER DATABASE remnawave OWNER TO remnawave;" 2>/dev/null || true
    
    # Import SQL dump
    if [[ -f "${backup_content_dir}/database.sql" ]]; then
        PGPASSWORD="$restore_db_password" sudo -u postgres psql -d remnawave < "${backup_content_dir}/database.sql"
    fi
    
    # Restore files
    info "Restoring application files..."
    # Сохраняем структуру директорий, но очищаем содержимое
    rm -rf "${APP_DIR:?}/data"/* 2>/dev/null || true
    rm -rf "${APP_DIR:?}/db"/* 2>/dev/null || true
    
    # Check if web server conversion is needed
    if [[ "$source_web_server" != "$WEB_SERVER" ]]; then
        info "Web server change detected: ${source_web_server} -> ${WEB_SERVER}"
        
        # Restore source web server files first for conversion
        if [[ "$source_web_server" == "nginx" ]] && [[ -d "${backup_content_dir}/nginx" ]]; then
            info "Restoring source Nginx files for conversion..."
            mkdir -p /opt/remnawave/nginx
            cp -r "${backup_content_dir}/nginx/"* /opt/remnawave/nginx/ 2>/dev/null || true
        elif [[ "$source_web_server" == "caddy" ]] && [[ -d "${backup_content_dir}/caddy" ]]; then
            info "Restoring source Caddy files for conversion..."
            mkdir -p /opt/remnawave/caddy
            cp -r "${backup_content_dir}/caddy/"* /opt/remnawave/caddy/ 2>/dev/null || true
        fi
        
        # Perform conversion
        handle_webserver_conversion "$source_web_server" "$WEB_SERVER"
    else
        # No conversion needed, restore normally
        if [[ "$WEB_SERVER" == "nginx" ]] && [[ -d "${backup_content_dir}/nginx" ]]; then
            info "Restoring Nginx SSL certificates and configuration..."
            mkdir -p /opt/remnawave/nginx
            cp -r "${backup_content_dir}/nginx/"* /opt/remnawave/nginx/ 2>/dev/null || true
            
            # Restart Nginx container
            cd /opt/remnawave/nginx
            if command -v docker &> /dev/null && docker compose version &> /dev/null; then
                docker compose restart
            elif command -v docker-compose &> /dev/null; then
                docker-compose restart
            fi
            
            info "Nginx SSL certificates restored"
        elif [[ "$WEB_SERVER" == "caddy" ]] && [[ -d "${backup_content_dir}/caddy" ]]; then
            info "Restoring Caddy configuration..."
            mkdir -p /opt/remnawave/caddy
            cp -r "${backup_content_dir}/caddy/"* /opt/remnawave/caddy/ 2>/dev/null || true
            
            # Reload Caddy
            systemctl reload caddy 2>/dev/null || true
            
            info "Caddy configuration restored"
        fi
    fi
    
    # Восстанавливаем данные приложения
    if [[ -d "${backup_content_dir}/data" ]]; then
        cp -r "${backup_content_dir}/data/"* "${APP_DIR}/data/" 2>/dev/null || true
    fi
    if [[ -d "${backup_content_dir}/db" ]]; then
        cp -r "${backup_content_dir}/db/"* "${APP_DIR}/db/" 2>/dev/null || true
    fi
    if [[ -f "${backup_content_dir}/docker-compose.yml" ]]; then
        cp "${backup_content_dir}/docker-compose.yml" "${APP_DIR}/" 2>/dev/null || true
    fi
    if [[ -f "${backup_content_dir}/app_env" ]]; then
        cp "${backup_content_dir}/app_env" "${APP_DIR}/.env" 2>/dev/null || true
    elif [[ -f "${backup_content_dir}/config.env" ]]; then
        cp "${backup_content_dir}/config.env" "${APP_DIR}/.env" 2>/dev/null || true
    fi
    
    # Restore config and update with new values
    info "Restoring configuration..."
    
    # Update domain in config if different (for migration scenarios)
    if [[ -n "$DOMAIN" ]] && [[ -f "${backup_content_dir}/config.env" ]]; then
        local old_domain=$(grep '^DOMAIN=' "${backup_content_dir}/config.env" 2>/dev/null | cut -d= -f2)
        if [[ "$DOMAIN" != "$old_domain" ]]; then
            info "Updating domain configuration from ${old_domain} to ${DOMAIN}..."
            sed -i "s|^DOMAIN=.*|DOMAIN=${DOMAIN}|" "${backup_content_dir}/config.env"
            
            # Copy updated config
            cp "${backup_content_dir}/config.env" "$CONFIG_FILE"
            
            # Update web server config for new domain
            update_webserver_config
        else
            cp "${backup_content_dir}/config.env" "$CONFIG_FILE"
        fi
    elif [[ -f "${backup_content_dir}/config.env" ]]; then
        cp "${backup_content_dir}/config.env" "$CONFIG_FILE"
    fi
    
    # Update database password in config if it changed
    if [[ -n "$DB_PASSWORD" ]] && [[ "$DB_PASSWORD" != "$restore_db_password" ]]; then
        info "Updating database password in configuration..."
        sed -i "s|DATABASE_URL=.*|DATABASE_URL=postgresql://remnawave:${DB_PASSWORD}@localhost:5432/remnawave|" "$CONFIG_FILE"
    fi
    
    # Cleanup
    rm -rf "$temp_dir"
    
    # Start services
    systemctl start remnawave 2>/dev/null || true
    
    info "Panel restored successfully"
}

# Update web server configuration for new domain
update_webserver_config() {
    info "Updating web server configuration for new domain..."
    
    if [[ "$WEB_SERVER" == "nginx" ]]; then
        # Update Nginx Docker config - regenerate with new domain
        create_nginx_config
        
        # Restart Nginx container
        cd /opt/remnawave/nginx
        if command -v docker &> /dev/null && docker compose version &> /dev/null; then
            docker compose down
            docker compose up -d
        elif command -v docker-compose &> /dev/null; then
            docker-compose down
            docker-compose up -d
        fi
        
        info "Nginx configuration updated for new domain"
        
        # Try to get new SSL certificate if domain changed
        if [[ -n "$DOMAIN" ]]; then
            info "Generating new SSL certificates for domain: $DOMAIN..."
            
            # Install acme.sh if not present
            if [[ ! -f ~/.acme.sh/acme.sh ]]; then
                curl https://get.acme.sh | sh -s email="$EMAIL" > /dev/null 2>&1
                source ~/.bashrc
                export PATH="$HOME/.acme.sh:$PATH"
            fi
            
            # Set default CA
            ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt
            
            # Generate new certificate
            ~/.acme.sh/acme.sh --issue --standalone -d "$DOMAIN" \
                --key-file /opt/remnawave/nginx/privkey.key \
                --fullchain-file /opt/remnawave/nginx/fullchain.pem \
                > /dev/null 2>&1 || warn "Could not obtain SSL certificate. Manual intervention may be required."
            
            # Restart Nginx to apply new certificates
            cd /opt/remnawave/nginx
            if command -v docker &> /dev/null && docker compose version &> /dev/null; then
                docker compose restart
            elif command -v docker-compose &> /dev/null; then
                docker-compose restart
            fi
            
            info "SSL certificates generated and Nginx restarted"
        fi
        
    elif [[ "$WEB_SERVER" == "caddy" ]]; then
        # Update Caddyfile
        cat > /etc/caddy/Caddyfile << EOF
${DOMAIN}, www.${DOMAIN} {
    reverse_proxy 127.0.0.1:3000
    
    # Security headers
    header {
        X-Frame-Options "SAMEORIGIN"
        X-Content-Type-Options "nosniff"
        X-XSS-Protection "1; mode=block"
    }
    
    # Static files
    handle_path /static/* {
        root * /opt/remnawave/public
        file_server
    }
}
EOF
        
        systemctl reload caddy
        info "Caddy configuration updated (SSL will be auto-provisioned)"
    fi
}

# Migrate panel from another server
migrate_panel() {
    info "Starting panel migration..."
    
    # Ask if domain will change
    echo -e "\n${BLUE}=== Migration Options ===${NC}"
    read -rp "Will the domain change during migration? (yes/no): " domain_change
    
    local source_server=$(get_input "Source server IP/hostname" "" "^[0-9a-zA-Z._-]+$")
    local source_user=$(get_input "Source server SSH user" "root")
    local source_port=$(get_input "Source server SSH port" "22" "^[0-9]+$")
    
    # Get new domain if it will change
    if [[ "$domain_change" == "yes" ]]; then
        DOMAIN=$(get_input "Enter NEW domain for this server" "" "^[a-zA-Z0-9.-]+$")
        EMAIL=$(get_input "Enter email for SSL certificates" "" "^[^@]+@[^@]+\.[^@]+$")
    fi
    
    # Create SSH key for migration if needed
    if [[ ! -f ~/.ssh/id_rsa ]]; then
        ssh-keygen -t rsa -b 4096 -f ~/.ssh/id_rsa -N "" -q
    fi
    
    # Test connection
    info "Testing connection to source server..."
    if ! ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no -p "$source_port" "${source_user}@${source_server}" "echo 'Connection successful'" > /dev/null 2>&1; then
        error "Failed to connect to source server"
        return 1
    fi
    
    # Copy backup from source or create one
    info "Copying backup from source server..."
    mkdir -p "$BACKUP_DIR"
    
    # Try to copy existing backup first
    if ! scp -o StrictHostKeyChecking=no -P "$source_port" "${source_user}@${source_server}:/opt/remnawave/backups/remnawave_backup_*.tar.gz" "$BACKUP_DIR/" 2>/dev/null; then
        warn "No backup found on source server. Creating one now..."
        
        # Run backup script on source server
        ssh -o StrictHostKeyChecking=no -p "$source_port" "${source_user}@${source_server}" \
            "/opt/remnawave/scripts/backup.sh" 2>/dev/null || {
            # If backup script doesn't exist, try manual backup
            ssh -o StrictHostKeyChecking=no -p "$source_port" "${source_user}@${source_server}" \
                "mkdir -p /tmp/remnawave_backup && \
                 sudo -u postgres pg_dump remnawave > /tmp/remnawave_backup/database.sql 2>/dev/null && \
                 cp /opt/remnawave/.env /tmp/remnawave_backup/config.env 2>/dev/null && \
                 cp -r /opt/remnawave /tmp/remnawave_backup/application 2>/dev/null && \
                 cd /tmp && tar -czf remnawave_manual_backup.tar.gz remnawave_backup && \
                 rm -rf /tmp/remnawave_backup"
        }
        
        # Copy the created backup
        scp -o StrictHostKeyChecking=no -P "$source_port" "${source_user}@${source_server}:/opt/remnawave/backups/remnawave_backup_*.tar.gz" "$BACKUP_DIR/" 2>/dev/null || \
        scp -o StrictHostKeyChecking=no -P "$source_port" "${source_user}@${source_server}:/tmp/remnawave_manual_backup.tar.gz" "$BACKUP_DIR/" 2>/dev/null || {
            error "Failed to create or copy backup from source server"
            return 1
        }
    fi
    
    # Get latest backup
    local latest_backup=$(ls -t "${BACKUP_DIR}"/remnawave_backup_*.tar.gz 2>/dev/null | head -1)
    
    if [[ -z "$latest_backup" ]]; then
        latest_backup=$(ls -t "${BACKUP_DIR}"/remnawave_manual_backup.tar.gz 2>/dev/null | head -1)
    fi
    
    if [[ -z "$latest_backup" ]]; then
        error "No backup file found after transfer"
        return 1
    fi
    
    info "Backup file: $latest_backup"
    
    # Load old config to get web server type
    local temp_extract=$(mktemp -d)
    tar -xzf "$latest_backup" -C "$temp_extract"
    local backup_content_dir=$(find "$temp_extract" -maxdepth 1 -type d -name "*backup*" | head -1)
    
    if [[ -f "${backup_content_dir}/config.env" ]]; then
        source "${backup_content_dir}/config.env" 2>/dev/null || true
        WEB_SERVER="${WEB_SERVER:-nginx}"
        rm -rf "$temp_extract"
    else
        rm -rf "$temp_extract"
        WEB_SERVER="nginx"
    fi
    
    # Restore backup (will handle domain update if needed)
    restore_panel "$latest_backup"
    
    info "Migration completed successfully"
    
    if [[ "$domain_change" == "yes" ]]; then
        echo -e "\n${GREEN}Domain updated to ${DOMAIN}${NC}"
        echo -e "${YELLOW}Note: Make sure DNS records point to this server's IP${NC}"
    fi
}

# Update panel
update_panel() {
    info "Checking for updates..."
    
    # Get current version info
    local current_version="unknown"
    if [[ -f /opt/remnawave/VERSION ]]; then
        current_version=$(cat /opt/remnawave/VERSION)
    fi
    info "Current version: $current_version"
    
    # Stop service
    systemctl stop remnawave 2>/dev/null || true
    
    # Backup current version
    info "Creating pre-update backup..."
    backup_panel
    
    # Download and extract update
    info "Downloading latest version..."
    local download_url="https://github.com/${GITHUB_REPO}/releases/latest/download/remnawave.tar.gz"
    
    if curl -sfL "$download_url" -o /tmp/remnawave_update.tar.gz 2>/dev/null; then
        # Backup current app files but preserve config
        cp -r /opt/remnawave /opt/remnawave.backup
        
        # Extract new version
        rm -rf /opt/remnawave/*
        tar xzf /tmp/remnawave_update.tar.gz -C /opt/remnawave --strip-components=1
        rm -f /tmp/remnawave_update.tar.gz
        
        # Restore config if it was overwritten
        if [[ -f /opt/remnawave.backup/.env ]]; then
            cp /opt/remnawave.backup/.env "${APP_DIR}/.env" 2>/dev/null || true
        fi
        
        # Cleanup backup
        rm -rf /opt/remnawave.backup
        
        # Run migrations
        info "Running database migrations..."
        if [[ -x /opt/remnawave/bin/remnawave ]]; then
            /opt/remnawave/bin/remnawave migrate 2>/dev/null || warn "Migrations may have failed"
        fi
        
        info "Update completed successfully"
    else
        warn "Could not download update. Check your internet connection."
        systemctl start remnawave 2>/dev/null || true
        return 1
    fi
    
    # Start service
    systemctl start remnawave
    
    # Verify service is running
    sleep 3
    if systemctl is-active --quiet remnawave; then
        info "RemnaWave is running after update"
    else
        error "RemnaWave failed to start after update. Restoring from backup..."
        return 1
    fi
}

# Uninstall panel
uninstall_panel() {
    warn "This will remove RemnaWave panel and all data!"
    read -rp "Are you sure? Type 'yes' to confirm: " confirm
    
    if [[ "$confirm" != "yes" ]]; then
        info "Uninstallation cancelled"
        return
    fi
    
    # Stop and disable services
    systemctl stop remnawave 2>/dev/null || true
    systemctl disable remnawave 2>/dev/null || true
    rm -f /etc/systemd/system/remnawave.service
    
    # Remove application
    rm -rf "${APP_DIR}" /var/log/remnawave "$BACKUP_DIR"
    
    # Remove database (optional)
    read -rp "Remove PostgreSQL database? (yes/no): " remove_db
    if [[ "$remove_db" == "yes" ]]; then
        sudo -u postgres psql -c "DROP DATABASE IF EXISTS remnawave;" 2>/dev/null || true
        sudo -u postgres psql -c "DROP USER IF EXISTS remnawave;" 2>/dev/null || true
    fi
    
    # Remove web server config
    if [[ "$WEB_SERVER" == "nginx" ]]; then
        rm -f /etc/nginx/sites-available/remnawave /etc/nginx/sites-enabled/remnawave
        systemctl reload nginx
    else
        systemctl stop caddy 2>/dev/null || true
        apt-get remove -y caddy 2>/dev/null || true
    fi
    
    info "RemnaWave uninstalled successfully"
}

# Show status
show_status() {
    echo -e "${CYAN}═══════════════════════════════════════${NC}"
    echo -e "${CYAN}Статус RemnaWave Panel:${NC}"
    echo -e "${CYAN}═══════════════════════════════════════${NC}"
    
    # Service status
    if systemctl is-active --quiet remnawave; then
        echo -e "Сервис: ${GREEN}Запущен${NC}"
    else
        echo -e "Сервис: ${RED}Остановлен${NC}"
    fi
    
    # Database status
    if systemctl is-active --quiet postgresql; then
        echo -e "PostgreSQL: ${GREEN}Запущен${NC}"
    else
        echo -e "PostgreSQL: ${RED}Остановлен${NC}"
    fi
    
    # Web server status
    if [[ "$WEB_SERVER" == "nginx" ]]; then
        if systemctl is-active --quiet nginx; then
            echo -e "Nginx: ${GREEN}Запущен${NC}"
        else
            echo -e "Nginx: ${RED}Остановлен${NC}"
        fi
    else
        if systemctl is-active --quiet caddy; then
            echo -e "Caddy: ${GREEN}Запущен${NC}"
        else
            echo -e "Caddy: ${RED}Остановлен${NC}"
        fi
    fi
    
    # Disk usage
    local usage=$(du -sh /opt/remnawave 2>/dev/null | cut -f1)
    echo -e "Размер приложения: ${usage:-Н/Д}"
    
    # Domain
    echo -e "Домен: ${DOMAIN:-не настроен}"
    
    # Backups count
    local backup_count=$(ls -1 "${BACKUP_DIR}"/remnawave_backup_*.tar.gz 2>/dev/null | wc -l)
    echo -e "Бэкапы: $backup_count"
    
    echo -e "${CYAN}═══════════════════════════════════════${NC}"
    echo ""
}

# Main menu
show_menu() {
    clear
    echo -e "${CYAN}╔════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║   RemnaWave Panel Installer v1.1       ║${NC}"
    echo -e "${CYAN}╚════════════════════════════════════════╝${NC}"
    echo ""
    
    if [[ -f /opt/remnawave/bin/remnawave ]]; then
        show_status
    fi
    
    echo -e "${BLUE}Главное меню:${NC}"
    echo "  1) Чистая установка панели"
    echo "  2) Миграция панели (с другого сервера)"
    echo "  3) Создать бэкап панели"
    echo "  4) Восстановить из бэкапа"
    echo "  5) Обновить панель"
    echo "  6) Удалить панель"
    echo "  7) Показать статус"
    echo "  8) Выход"
    echo ""
    read -rp "Выберите опцию [1-8]: " choice
    
    case $choice in
        1)
            INSTALL_MODE="clean"
            configure_installation
            ;;
        2)
            INSTALL_MODE="migrate"
            configure_installation
            ;;
        3)
            backup_panel
            echo -e "\n${GREEN}Нажмите Enter для продолжения...${NC}"
            read
            show_menu
            ;;
        4)
            echo "Доступные бэкапы:"
            ls -lh "${BACKUP_DIR}"/remnawave_backup_*.tar.gz 2>/dev/null || echo "Бэкапы не найдены"
            echo ""
            read -rp "Введите путь к файлу бэкапа: " backup_file
            restore_panel "$backup_file"
            echo -e "\n${GREEN}Нажмите Enter для продолжения...${NC}"
            read
            show_menu
            ;;
        5)
            update_panel
            echo -e "\n${GREEN}Нажмите Enter для продолжения...${NC}"
            read
            show_menu
            ;;
        6)
            uninstall_panel
            echo -e "\n${GREEN}Нажмите Enter для продолжения...${NC}"
            read
            show_menu
            ;;
        7)
            show_status
            echo -e "${GREEN}Нажмите Enter для продолжения...${NC}"
            read
            show_menu
            ;;
        8)
            info "Goodbye!"
            exit 0
            ;;
        *)
            warn "Invalid option"
            sleep 1
            show_menu
            ;;
    esac
}

# Configure installation settings
configure_installation() {
    echo -e "\n${BLUE}=== Installation Configuration ===${NC}\n"
    
    # Domain configuration
    DOMAIN=$(get_input "Enter your domain (e.g., panel.example.com)" "" "^[a-zA-Z0-9.-]+$")
    
    # Email for SSL certificates
    EMAIL=$(get_input "Enter email for SSL certificates" "" "^[^@]+@[^@]+\.[^@]+$")
    
    # Web server selection
    echo -e "\nSelect web server:"
    echo "  1) Nginx (with Certbot for SSL)"
    echo "  2) Caddy (automatic SSL)"
    read -rp "Choice [1-2]: " web_choice
    
    case $web_choice in
        1) WEB_SERVER="nginx" ;;
        2) WEB_SERVER="caddy" ;;
        *) WEB_SERVER="nginx" ;;
    esac
    
    # Admin credentials
    echo -e "\n=== Admin Account ==="
    ADMIN_USERNAME=$(get_input "Admin username" "admin" "^[a-zA-Z0-9_-]{3,20}$")
    
    if [[ -z "$ADMIN_PASSWORD" ]]; then
        ADMIN_PASSWORD=$(generate_secret | cut -c1-16)
        echo -e "${YELLOW}Generated admin password: ${ADMIN_PASSWORD}${NC}"
        echo -e "${YELLOW}Please save this password!${NC}\n"
    fi
    
    # Database password
    if [[ -z "$DB_PASSWORD" ]]; then
        DB_PASSWORD=$(generate_secret)
    fi
    
    # JWT Secret
    JWT_SECRET=$(generate_secret)
    
    # Confirm settings
    echo -e "\n${BLUE}=== Configuration Summary ===${NC}"
    echo "Domain: $DOMAIN"
    echo "Email: $EMAIL"
    echo "Web Server: $WEB_SERVER"
    echo "Admin Username: $ADMIN_USERNAME"
    echo "Database: PostgreSQL $PG_VERSION"
    echo ""
    
    read -rp "Proceed with installation? (yes/no): " confirm
    if [[ "$confirm" != "yes" ]]; then
        info "Installation cancelled"
        show_menu
        return
    fi
    
    # Run installation
    run_installation
}

# Run the installation process
run_installation() {
    echo -e "\n${CYAN}=== Starting Installation ===${NC}\n"
    
    check_requirements
    install_dependencies
    
    if [[ "$INSTALL_MODE" == "clean" ]]; then
        setup_postgresql
        setup_webserver
        install_application
        setup_service
    elif [[ "$INSTALL_MODE" == "migrate" ]]; then
        migrate_panel
    fi
    
    # Final checks
    sleep 5
    if systemctl is-active --quiet remnawave; then
        echo -e "\n${GREEN}╔════════════════════════════════════════╗${NC}"
        echo -e "${GREEN}║     Installation Completed! ✓           ║${NC}"
        echo -e "${GREEN}╚════════════════════════════════════════╝${NC}"
        echo ""
        echo "Access your panel at: https://${DOMAIN}"
        echo "Admin username: ${ADMIN_USERNAME}"
        echo "Admin password: ${ADMIN_PASSWORD}"
        echo ""
        echo "Important files:"
        echo "  Config: ${CONFIG_FILE}"
        echo "  Logs: /var/log/remnawave/"
        echo "  Backups: ${BACKUP_DIR}/"
        echo ""
        echo "Useful commands:"
        echo "  systemctl status remnawave  # Check service status"
        echo "  journalctl -u remnawave -f  # View logs"
        echo "  /opt/remnawave/scripts/backup.sh  # Manual backup"
        echo ""
    else
        error "Installation completed with errors. Check logs: ${LOG_FILE}"
    fi
    
    echo -e "${GREEN}Нажмите Enter для возврата в меню...${NC}"
    read
    show_menu
}

# Signal handler for cleanup
cleanup() {
    warn "Installation interrupted"
    exit 1
}

trap cleanup SIGINT SIGTERM

# Main entry point
main() {
    check_root
    
    # Create log directory
    mkdir -p "$(dirname "$LOG_FILE")"
    
    info "RemnaWave Installation Script started"
    info "Log file: ${LOG_FILE}"
    
    show_menu
}

# Run if executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
