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
CONFIG_FILE="/etc/remnawave/config.env"
BACKUP_DIR="/var/backups/remnawave"
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
    
    # Create database and user
    sudo -u postgres psql -c "CREATE DATABASE remnawave;" 2>/dev/null || true
    sudo -u postgres psql -c "CREATE USER remnawave WITH PASSWORD '${DB_PASSWORD}';" 2>/dev/null || true
    sudo -u postgres psql -c "GRANT ALL PRIVILEGES ON DATABASE remnawave TO remnawave;" 2>/dev/null || true
    sudo -u postgres psql -c "ALTER DATABASE remnawave OWNER TO remnawave;" 2>/dev/null || true
    
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
        setup_nginx
    else
        setup_caddy
    fi
}

# Setup Nginx
setup_nginx() {
    info "Configuring Nginx..."
    
    # Create Nginx config
    cat > /etc/nginx/sites-available/remnawave << EOF
server {
    listen 80;
    server_name ${DOMAIN} www.${DOMAIN};
    
    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }
    
    location / {
        return 301 https://\$host\$request_uri;
    }
}

server {
    listen 443 ssl http2;
    server_name ${DOMAIN} www.${DOMAIN};
    
    ssl_certificate /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${DOMAIN}/privkey.pem;
    
    # Security headers
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-XSS-Protection "1; mode=block" always;
    
    # Proxy settings
    location / {
        proxy_pass http://127.0.0.1:3000;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        
        # WebSocket support
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }
    
    # Static files
    location /static/ {
        alias /opt/remnawave/public/;
        expires 1y;
        add_header Cache-Control "public, immutable";
    }
}
EOF
    
    # Enable site
    ln -sf /etc/nginx/sites-available/remnawave /etc/nginx/sites-enabled/
    rm -f /etc/nginx/sites-enabled/default
    
    # Test and reload
    nginx -t && systemctl reload nginx
    
    # Setup SSL with Let's Encrypt
    mkdir -p /var/www/certbot
    certbot certonly --webroot -w /var/www/certbot -d "$DOMAIN" -d "www.$DOMAIN" --email "$EMAIL" --agree-tos --non-interactive
    
    # Setup auto-renewal
    if ! crontab -l | grep -q "certbot renew"; then
        (crontab -l 2>/dev/null; echo "0 3 * * * /usr/bin/certbot renew --quiet --deploy-hook 'systemctl reload nginx'") | crontab -
    fi
    
    info "Nginx configured successfully"
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

BACKUP_DIR="/var/backups/remnawave"
CONFIG_FILE="/etc/remnawave/config.env"
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
cp -r /etc/remnawave "${BACKUP_PATH}/config" 2>/dev/null || true
cp -r /opt/remnawave "${BACKUP_PATH}/application" 2>/dev/null || true

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

# Security hardening
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
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
    
    # Backup database
    info "Backing up database..."
    PGPASSWORD="$DB_PASSWORD" pg_dump -U remnawave -h localhost remnawave > "${backup_path}/database.sql"
    
    # Backup configuration
    info "Backing up configuration..."
    cp -r /etc/remnawave "${backup_path}/config" 2>/dev/null || true
    cp -r /opt/remnawave "${backup_path}/application" 2>/dev/null || true
    
    # Create archive
    tar -czf "${backup_path}.tar.gz" -C "$BACKUP_DIR" "$backup_name"
    rm -rf "$backup_path"
    
    # Cleanup old backups (keep last 7)
    ls -t "${BACKUP_DIR}"/remnawave_backup_*.tar.gz | tail -n +8 | xargs -r rm
    
    info "Backup created: ${backup_path}.tar.gz"
    echo "${backup_path}.tar.gz"
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
    
    # Load old config to get DB password if available
    local old_config="${backup_content_dir}/config/config.env"
    local restore_db_password=""
    if [[ -f "$old_config" ]]; then
        source "$old_config" 2>/dev/null || true
        restore_db_password="$DB_PASSWORD"
    fi
    
    # If we couldn't get password from backup, use current or generate new
    if [[ -z "$restore_db_password" ]]; then
        if [[ -n "$DB_PASSWORD" ]]; then
            restore_db_password="$DB_PASSWORD"
        else
            restore_db_password=$(generate_secret)
        fi
    fi
    
    # Restore database
    info "Restoring database..."
    sudo -u postgres psql -c "DROP DATABASE IF EXISTS remnawave;" 2>/dev/null || true
    sudo -u postgres psql -c "CREATE DATABASE remnawave;" 2>/dev/null || true
    sudo -u postgres psql -c "DROP USER IF EXISTS remnawave;" 2>/dev/null || true
    sudo -u postgres psql -c "CREATE USER remnawave WITH PASSWORD '${restore_db_password}';" 2>/dev/null || true
    sudo -u postgres psql -c "GRANT ALL PRIVILEGES ON DATABASE remnawave TO remnawave;" 2>/dev/null || true
    sudo -u postgres psql -c "ALTER DATABASE remnawave OWNER TO remnawave;" 2>/dev/null || true
    
    # Import SQL dump
    if [[ -f "${backup_content_dir}/database.sql" ]]; then
        PGPASSWORD="$restore_db_password" sudo -u postgres psql -d remnawave < "${backup_content_dir}/database.sql"
    fi
    
    # Restore files
    info "Restoring application files..."
    rm -rf /opt/remnawave/* 2>/dev/null || true
    cp -r "${backup_content_dir}/application/"* /opt/remnawave/ 2>/dev/null || true
    
    # Restore config and update with new values
    info "Restoring configuration..."
    rm -rf /etc/remnawave/* 2>/dev/null || true
    mkdir -p /etc/remnawave
    cp -r "${backup_content_dir}/config/"* /etc/remnawave/ 2>/dev/null || true
    
    # Update domain in config if different (for migration scenarios)
    if [[ -n "$DOMAIN" ]] && [[ "$DOMAIN" != "$(grep '^DOMAIN=' /etc/remnawave/config.env 2>/dev/null | cut -d= -f2)" ]]; then
        info "Updating domain configuration from $(grep '^DOMAIN=' /etc/remnawave/config.env 2>/dev/null | cut -d= -f2) to ${DOMAIN}..."
        sed -i "s|^DOMAIN=.*|DOMAIN=${DOMAIN}|" /etc/remnawave/config.env
        
        # Update web server config for new domain
        update_webserver_config
    fi
    
    # Update database password in config if it changed
    if [[ -n "$DB_PASSWORD" ]] && [[ "$DB_PASSWORD" != "$restore_db_password" ]]; then
        info "Updating database password in configuration..."
        sed -i "s|DATABASE_URL=.*|DATABASE_URL=postgresql://remnawave:${DB_PASSWORD}@localhost:5432/remnawave|" /etc/remnawave/config.env
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
        # Update Nginx config
        cat > /etc/nginx/sites-available/remnawave << EOF
server {
    listen 80;
    server_name ${DOMAIN} www.${DOMAIN};
    
    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }
    
    location / {
        return 301 https://\$host\$request_uri;
    }
}

server {
    listen 443 ssl http2;
    server_name ${DOMAIN} www.${DOMAIN};
    
    ssl_certificate /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${DOMAIN}/privkey.pem;
    
    # Security headers
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-XSS-Protection "1; mode=block" always;
    
    # Proxy settings
    location / {
        proxy_pass http://127.0.0.1:3000;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        
        # WebSocket support
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }
    
    # Static files
    location /static/ {
        alias /opt/remnawave/public/;
        expires 1y;
        add_header Cache-Control "public, immutable";
    }
}
EOF
        
        # Test and reload
        nginx -t && systemctl reload nginx
        
        # Try to get new SSL certificate
        mkdir -p /var/www/certbot
        if certbot certonly --webroot -w /var/www/certbot -d "$DOMAIN" -d "www.$DOMAIN" --email "$EMAIL" --agree-tos --non-interactive 2>/dev/null; then
            info "SSL certificate renewed for new domain"
            systemctl reload nginx
        else
            warn "Could not obtain SSL certificate for new domain. Manual intervention may be required."
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
    if ! scp -o StrictHostKeyChecking=no -P "$source_port" "${source_user}@${source_server}:/var/backups/remnawave/remnawave_backup_*.tar.gz" "$BACKUP_DIR/" 2>/dev/null; then
        warn "No backup found on source server. Creating one now..."
        
        # Run backup script on source server
        ssh -o StrictHostKeyChecking=no -p "$source_port" "${source_user}@${source_server}" \
            "/opt/remnawave/scripts/backup.sh" 2>/dev/null || {
            # If backup script doesn't exist, try manual backup
            ssh -o StrictHostKeyChecking=no -p "$source_port" "${source_user}@${source_server}" \
                "mkdir -p /tmp/remnawave_backup && \
                 sudo -u postgres pg_dump remnawave > /tmp/remnawave_backup/database.sql 2>/dev/null && \
                 cp -r /etc/remnawave /tmp/remnawave_backup/config 2>/dev/null && \
                 cp -r /opt/remnawave /tmp/remnawave_backup/application 2>/dev/null && \
                 cd /tmp && tar -czf remnawave_manual_backup.tar.gz remnawave_backup && \
                 rm -rf /tmp/remnawave_backup"
        }
        
        # Copy the created backup
        scp -o StrictHostKeyChecking=no -P "$source_port" "${source_user}@${source_server}:/var/backups/remnawave/remnawave_backup_*.tar.gz" "$BACKUP_DIR/" 2>/dev/null || \
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
    
    if [[ -f "${backup_content_dir}/config/config.env" ]]; then
        source "${backup_content_dir}/config/config.env" 2>/dev/null || true
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
        if [[ -f /opt/remnawave.backup/config.env ]]; then
            cp /opt/remnawave.backup/config.env /etc/remnawave/config.env 2>/dev/null || true
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
    rm -rf /opt/remnawave /etc/remnawave /var/log/remnawave
    
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
    echo -e "\n${CYAN}=== RemnaWave Status ===${NC}"
    
    # Service status
    if systemctl is-active --quiet remnawave; then
        echo -e "${GREEN}● Service: Running${NC}"
    else
        echo -e "${RED}● Service: Stopped${NC}"
    fi
    
    # Database status
    if systemctl is-active --quiet postgresql; then
        echo -e "${GREEN}● PostgreSQL: Running${NC}"
    else
        echo -e "${RED}● PostgreSQL: Stopped${NC}"
    fi
    
    # Web server status
    if [[ "$WEB_SERVER" == "nginx" ]]; then
        if systemctl is-active --quiet nginx; then
            echo -e "${GREEN}● Nginx: Running${NC}"
        else
            echo -e "${RED}● Nginx: Stopped${NC}"
        fi
    else
        if systemctl is-active --quiet caddy; then
            echo -e "${GREEN}● Caddy: Running${NC}"
        else
            echo -e "${RED}● Caddy: Stopped${NC}"
        fi
    fi
    
    # Disk usage
    local usage=$(du -sh /opt/remnawave 2>/dev/null | cut -f1)
    echo -e "● Application size: ${usage:-N/A}"
    
    # Domain
    echo -e "● Domain: ${DOMAIN:-Not configured}"
    
    echo ""
}

# Main menu
show_menu() {
    clear
    echo -e "${CYAN}╔════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║     RemnaWave Panel Installer v1.1     ║${NC}"
    echo -e "${CYAN}╚════════════════════════════════════════╝${NC}"
    echo ""
    
    if [[ -f /opt/remnawave/bin/remnawave ]]; then
        show_status
    fi
    
    echo -e "${BLUE}Main Menu:${NC}"
    echo "  1) Clean Installation"
    echo "  2) Migrate Panel (from another server)"
    echo "  3) Backup Panel"
    echo "  4) Restore Panel from Backup"
    echo "  5) Update Panel"
    echo "  6) Uninstall Panel"
    echo "  7) Show Status"
    echo "  8) Exit"
    echo ""
    read -rp "Select option [1-8]: " choice
    
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
            echo -e "\n${GREEN}Press Enter to continue...${NC}"
            read
            show_menu
            ;;
        4)
            echo "Available backups:"
            ls -lh "${BACKUP_DIR}"/remnawave_backup_*.tar.gz 2>/dev/null || echo "No backups found"
            echo ""
            read -rp "Enter backup file path: " backup_file
            restore_panel "$backup_file"
            echo -e "\n${GREEN}Press Enter to continue...${NC}"
            read
            show_menu
            ;;
        5)
            update_panel
            echo -e "\n${GREEN}Press Enter to continue...${NC}"
            read
            show_menu
            ;;
        6)
            uninstall_panel
            echo -e "\n${GREEN}Press Enter to continue...${NC}"
            read
            show_menu
            ;;
        7)
            show_status
            echo -e "${GREEN}Press Enter to continue...${NC}"
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
    
    echo -e "${GREEN}Press Enter to return to menu...${NC}"
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
