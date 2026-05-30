#!/bin/bash
# =============================================================================
# RemnaWave One-Click Installer
# Repository: https://github.com/Armruswest2024/remnainstabac
# Usage: bash <(curl -sL https://raw.githubusercontent.com/Armruswest2024/remnainstabac/main/install.sh)
# =============================================================================

set -e

# 🎨 Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# ⚙️ Configuration
REPO_URL="https://github.com/Armruswest2024/remnainstabac"
INSTALL_DIR="/opt/remnawave"
DOCKER_COMPOSE_FILE="${INSTALL_DIR}/docker-compose.yml"
ENV_FILE="${INSTALL_DIR}/.env"
DB_NAME="remnawave"
DB_USER="remnawave"
DB_PASSWORD=$(openssl rand -base64 32)
JWT_SECRET=$(openssl rand -base64 32)
ADMIN_PASSWORD=$(openssl rand -base64 16)
POSTGRES_VERSION="17"
REDNAWAVE_IMAGE="remnawave/remnawave:latest"

# 📋 Logging functions
log_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[✓]${NC} $1"; }
log_warn()    { echo -e "${YELLOW}[!]${NC} $1"; }
log_error()   { echo -e "${RED}[✗]${NC} $1"; }

# 🔍 Check if running as root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root!"
        exit 1
    fi
}

# 🌐 Check internet connection
check_internet() {
    if ! ping -c 1 8.8.8.8 &> /dev/null; then
        log_error "No internet connection detected!"
        exit 1
    fi
    log_success "Internet connection verified"
}

# 📦 Install system dependencies
install_dependencies() {
    log_info "Installing system dependencies..."
    
    if command -v apt-get &> /dev/null; then
        apt-get update -qq
        apt-get install -y -qq curl wget git apt-transport-https ca-certificates gnupg lsb-release software-properties-common
    elif command -v yum &> /dev/null; then
        yum install -y -q epel-release
        yum install -y -q curl wget git
    elif command -v dnf &> /dev/null; then
        dnf install -y -q curl wget git
    else
        log_error "Unsupported package manager!"
        exit 1
    fi
    log_success "Dependencies installed"
}

# 🐳 Install Docker
install_docker() {
    if command -v docker &> /dev/null; then
        log_success "Docker is already installed"
        return
    fi
    
    log_info "Installing Docker..."
    
    if command -v apt-get &> /dev/null; then
        mkdir -p /etc/apt/keyrings
        curl -fsSL https://download.docker.com/linux/$(lsb_release -is | tr '[:upper:]' '[:lower:]')/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/$(lsb_release -is | tr '[:upper:]' '[:lower:]') $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
        apt-get update -qq
        apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-compose-plugin
    elif command -v yum &> /dev/null || command -v dnf &> /dev/null; then
        curl -fsSL https://get.docker.com | sh
    fi
    
    systemctl enable --now docker
    usermod -aG docker root 2>/dev/null || true
    log_success "Docker installed successfully"
}

# 🐙 Install Docker Compose
install_docker_compose() {
    if command -v docker-compose &> /dev/null || docker compose version &> /dev/null; then
        log_success "Docker Compose is already installed"
        return
    fi
    
    log_info "Installing Docker Compose..."
    DOCKER_COMPOSE_VERSION=$(curl -s https://api.github.com/repos/docker/compose/releases/latest | grep tag_name | cut -d '"' -f 4)
    curl -L "https://github.com/docker/compose/releases/download/${DOCKER_COMPOSE_VERSION}/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
    chmod +x /usr/local/bin/docker-compose
    log_success "Docker Compose installed"
}

# 🔐 Generate configuration files
generate_config() {
    log_info "Generating configuration files..."
    mkdir -p "${INSTALL_DIR}"
    
    # Create .env file
    cat > "${ENV_FILE}" << EOF
# RemnaWave Environment Configuration
# Generated: $(date)

# Database
POSTGRES_DB=${DB_NAME}
POSTGRES_USER=${DB_USER}
POSTGRES_PASSWORD=${DB_PASSWORD}
POSTGRES_VERSION=${POSTGRES_VERSION}

# Application
JWT_SECRET=${JWT_SECRET}
ADMIN_PASSWORD=${ADMIN_PASSWORD}
APP_PORT=3000
APP_ENV=production

# Database URL for application
DATABASE_URL=postgresql://${DB_USER}:${DB_PASSWORD}@postgres:5432/${DB_NAME}?schema=public

# Optional: Custom domain (uncomment and set if using)
# APP_DOMAIN=your-domain.com
# ENABLE_SSL=true
EOF
    chmod 600 "${ENV_FILE}"
    
    # Create docker-compose.yml
    cat > "${DOCKER_COMPOSE_FILE}" << 'EOF'
version: '3.8'

services:
  postgres:
    image: postgres:${POSTGRES_VERSION:-17}-alpine
    container_name: remnawave_postgres
    restart: unless-stopped
    environment:
      POSTGRES_DB: ${POSTGRES_DB}
      POSTGRES_USER: ${POSTGRES_USER}
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
    volumes:
      - postgres_data:/var/lib/postgresql/data
      - ./init.sql:/docker-entrypoint-initdb.d/init.sql:ro
    networks:
      - remnawave_net
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${POSTGRES_USER} -d ${POSTGRES_DB}"]
      interval: 10s
      timeout: 5s
      retries: 5

  remnawave:
    image: ${REDNAWAVE_IMAGE:-remnawave/remnawave:latest}
    container_name: remnawave_app
    restart: unless-stopped
    depends_on:
      postgres:
        condition: service_healthy
    environment:
      DATABASE_URL: ${DATABASE_URL}
      JWT_SECRET: ${JWT_SECRET}
      ADMIN_PASSWORD: ${ADMIN_PASSWORD}
      APP_ENV: ${APP_ENV:-production}
      PORT: ${APP_PORT:-3000}
    ports:
      - "${APP_PORT:-3000}:3000"
    volumes:
      - ./config:/app/config:ro
      - ./logs:/app/logs
    networks:
      - remnawave_net
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:3000/health"]
      interval: 30s
      timeout: 10s
      retries: 3

networks:
  remnawave_net:
    driver: bridge

volumes:
  postgres_data:
EOF
    
    log_success "Configuration files generated"
}

# 🗄️ Create optional database initialization script
create_init_sql() {
    # Create empty init.sql or add custom migrations here
    cat > "${INSTALL_DIR}/init.sql" << 'EOF'
-- Optional: Custom database initialization scripts
-- This file will be executed on first database start
-- Example:
-- CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
EOF
    log_info "Database initialization script created"
}

# 🚀 Start the application
start_application() {
    log_info "Starting RemnaWave services..."
    cd "${INSTALL_DIR}"
    
    # Pull images
    docker compose pull -q
    
    # Start services
    docker compose up -d
    
    # Wait for services to be healthy
    log_info "Waiting for services to start..."
    sleep 15
    
    # Check status
    if docker compose ps | grep -q "Up"; then
        log_success "RemnaWave is running!"
    else
        log_warn "Services may still be starting. Check with: docker compose ps"
    fi
}

# 🔧 Configure firewall (optional)
configure_firewall() {
    log_info "Configuring firewall..."
    
    if command -v ufw &> /dev/null && ufw status | grep -q "Status: inactive"; then
        ufw allow 22/tcp
        ufw allow 3000/tcp
        ufw --force enable
        log_success "Firewall configured (ports 22, 3000)"
    elif command -v firewall-cmd &> /dev/null; then
        firewall-cmd --permanent --add-port=3000/tcp 2>/dev/null || true
        firewall-cmd --reload 2>/dev/null || true
        log_success "Firewall rules updated"
    else
        log_warn "No firewall detected or already configured"
    fi
}

# 📊 Display installation summary
show_summary() {
    echo ""
    echo -e "${GREEN}╔════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║${NC}  ${BLUE}🎉 RemnaWave Installation Complete!${NC}  ${GREEN}║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${YELLOW}📋 Access Information:${NC}"
    echo "   ┌─────────────────────────────────"
    echo "   │ URL:      http://<YOUR_SERVER_IP>:3000"
    echo "   │ Username: admin"
    echo "   │ Password: ${ADMIN_PASSWORD}"
    echo "   └─────────────────────────────────"
    echo ""
    echo -e "${YELLOW}🔐 IMPORTANT - Save these credentials:${NC}"
    echo "   Database Password: ${DB_PASSWORD}"
    echo "   JWT Secret: ${JWT_SECRET}"
    echo ""
    echo -e "${YELLOW}🛠️ Useful Commands:${NC}"
    echo "   • View logs:     cd ${INSTALL_DIR} && docker compose logs -f"
    echo "   • Restart:       cd ${INSTALL_DIR} && docker compose restart"
    echo "   • Stop:          cd ${INSTALL_DIR} && docker compose down"
    echo "   • Update:        cd ${INSTALL_DIR} && docker compose pull && docker compose up -d"
    echo "   • Backup DB:     docker exec remnawave_postgres pg_dump -U ${DB_USER} ${DB_NAME} > backup.sql"
    echo ""
    echo -e "${YELLOW}🔗 Repository:${NC}"
    echo "   ${REPO_URL}"
    echo ""
}

# 🔄 Update function (can be called separately)
update_remnawave() {
    log_info "Updating RemnaWave..."
    cd "${INSTALL_DIR}"
    docker compose pull
    docker compose up -d
    log_success "Update completed!"
}

# 🧹 Cleanup function
cleanup() {
    log_info "Cleaning up temporary files..."
    # Add cleanup logic here if needed
}

# 🎯 Main installation flow
main() {
    echo ""
    echo -e "${BLUE}╔════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║${NC}  🚀 RemnaWave One-Click Installer     ${BLUE}║${NC}"
    echo -e "${BLUE}║${NC}  Repo: ${REPO_URL}  ${BLUE}║${NC}"
    echo -e "${BLUE}╚════════════════════════════════════════════╝${NC}"
    echo ""
    
    # Pre-flight checks
    check_root
    check_internet
    
    # Installation steps
    install_dependencies
    install_docker
    install_docker_compose
    generate_config
    create_init_sql
    configure_firewall
    start_application
    show_summary
    
    # Cleanup
    cleanup
    
    log_success "Installation finished successfully! 🎉"
}

# Handle command line arguments
case "${1:-install}" in
    install)
        main
        ;;
    update)
        install_docker
        install_docker_compose
        update_remnawave
        ;;
    backup)
        cd "${INSTALL_DIR}"
        docker exec remnawave_postgres pg_dump -U ${DB_USER} ${DB_NAME} > "backup_$(date +%Y%m%d_%H%M%S).sql"
        log_success "Backup created!"
        ;;
    logs)
        cd "${INSTALL_DIR}"
        docker compose logs -f "${2:-}"
        ;;
    help|--help|-h)
        echo "Usage: $0 [command]"
        echo ""
        echo "Commands:"
        echo "  install   - Install RemnaWave (default)"
        echo "  update    - Update to latest version"
        echo "  backup    - Create database backup"
        echo "  logs      - View application logs"
        echo "  help      - Show this help message"
        ;;
    *)
        log_error "Unknown command: $1"
        echo "Use '$0 help' for usage information"
        exit 1
        ;;
esac
