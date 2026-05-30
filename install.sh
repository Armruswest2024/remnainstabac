#!/bin/bash

# RemnaWave Panel Installation Script
# Version: 1.0.0
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
PG_VERSION="17"
DOMAIN=""
EMAIL=""
WEB_SERVER=""
INSTALL_MODE=""
DB_PASSWORD=""
ADMIN_USERNAME=""
ADMIN_PASSWORD=""
JWT_SECRET=""

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
    
    info "Dependencies installed successfully"
}

# Configure PostgreSQL
setup_postgresql() {
    info "Configuring PostgreSQL..."
    
    # Start PostgreSQL
    systemctl enable --now postgresql
    
    # Generate database password if not set
    if [[ -z "$DB_PASSWORD" ]]; then
        DB_PASSWORD=$(generate_secret)
    fi
    
    # Create database and user
    sudo -u postgres psql -c "CREATE DATABASE remnawave;" 2>/dev/null || true
    sudo -u postgres psql -c "CREATE USER remnawave WITH PASSWORD '${DB_PASSWORD}';" 2>/dev/null || true
    sudo -u postgres psql -c "GRANT ALL PRIVILEGES ON DATABASE remnawave TO remnawave;" 2>/dev/null || true
    
    # Configure pg_hba.conf for local connections
    if ! grep -q "remnawave" /etc/postgresql/*/main/pg_hba.conf 2>/dev/null; then
        echo "local   remnawave   remnawave   md5" >> /etc/postgresql/*/main/pg_hba.conf 2>/dev/null || true
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
    mkdir -p /opt/remnawave /var/log/remnawave "$BACKUP_DIR"
    
    # Download latest release (placeholder - replace with actual download)
    # curl -L https://github.com/remnawave/remnawave/releases/latest/download/remnawave.tar.gz | tar xz -C /opt/remnawave
    
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
    
    info "Application installed successfully"
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
    
    # Restore database
    info "Restoring database..."
    sudo -u postgres psql -c "DROP DATABASE IF EXISTS remnawave;" 2>/dev/null || true
    sudo -u postgres psql -c "CREATE DATABASE remnawave;" 2>/dev/null || true
    PGPASSWORD="$DB_PASSWORD" psql -U remnawave -h localhost -d remnawave < "${temp_dir}"/remnawave_backup_*/database.sql
    
    # Restore files
    info "Restoring application files..."
    cp -r "${temp_dir}"/remnawave_backup_*/application/* /opt/remnawave/ 2>/dev/null || true
    cp -r "${temp_dir}"/remnawave_backup_*/config/* /etc/remnawave/ 2>/dev/null || true
    
    # Cleanup
    rm -rf "$temp_dir"
    
    # Start services
    systemctl start remnawave
    
    info "Panel restored successfully"
}

# Migrate panel from another server
migrate_panel() {
    info "Starting panel migration..."
    
    local source_server=$(get_input "Source server IP/hostname" "" "^[0-9a-zA-Z._-]+$")
    local source_user=$(get_input "Source server SSH user" "root")
    local source_port=$(get_input "Source server SSH port" "22" "^[0-9]+$")
    
    # Create SSH key for migration if needed
    if [[ ! -f ~/.ssh/id_rsa ]]; then
        ssh-keygen -t rsa -b 4096 -f ~/.ssh/id_rsa -N "" -q
    fi
    
    # Test connection
    info "Testing connection to source server..."
    if ! ssh -o ConnectTimeout=10 -p "$source_port" "${source_user}@${source_server}" "echo 'Connection successful'" > /dev/null 2>&1; then
        error "Failed to connect to source server"
        return 1
    fi
    
    # Copy backup from source
    info "Copying backup from source server..."
    scp -P "$source_port" "${source_user}@${source_server}:/var/backups/remnawave/remnawave_backup_*.tar.gz" "$BACKUP_DIR/" 2>/dev/null || {
        warn "No backup found on source server. Creating one now..."
        ssh -p "$source_port" "${source_user}@${source_server}" "/opt/remnawave/scripts/backup.sh"
        scp -P "$source_port" "${source_user}@${source_server}:/var/backups/remnawave/remnawave_backup_*.tar.gz" "$BACKUP_DIR/"
    }
    
    # Get latest backup
    local latest_backup=$(ls -t "${BACKUP_DIR}"/remnawave_backup_*.tar.gz | head -1)
    
    # Restore backup
    restore_panel "$latest_backup"
    
    # Update domain in config if different
    if [[ "$DOMAIN" != "$(grep '^DOMAIN=' /etc/remnawave/config.env | cut -d= -f2)" ]]; then
        info "Updating domain configuration..."
        sed -i "s|^DOMAIN=.*|DOMAIN=${DOMAIN}|" /etc/remnawave/config.env
    fi
    
    info "Migration completed successfully"
}

# Update panel
update_panel() {
    info "Checking for updates..."
    
    # Stop service
    systemctl stop remnawave
    
    # Backup current version
    backup_panel
    
    # Download and extract update
    # curl -L https://github.com/remnawave/remnawave/releases/latest/download/remnawave.tar.gz | tar xz -C /opt/remnawave
    
    # Run migrations
    # /opt/remnawave/bin/remnawave migrate
    
    # Start service
    systemctl start remnawave
    
    info "Update completed successfully"
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
    echo -e "${CYAN}║     RemnaWave Panel Installer v1.0     ║${NC}"
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
