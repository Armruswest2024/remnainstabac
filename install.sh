#!/bin/bash

# set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
PURPLE='\033[0;35m'
BOLD='\033[1m'
NC='\033[0m'

APP_DIR="/opt/remnawave"
NGINX_DIR="${APP_DIR}/nginx"
SUB_DIR="${APP_DIR}/subscription"
BACKUP_DIR="${APP_DIR}/backups"
LOG_FILE="/var/log/remnawave_install.log"
CONFIG_FILE="${APP_DIR}/.env"

info() { echo -e "${GREEN}[✓]${NC} $1"; log "INFO" "$1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; log "WARN" "$1"; }
error() { echo -e "${RED}[✗]${NC} $1"; log "ERROR" "$1"; }

log() {
    local level="$1"
    local message="$2"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo -e "${timestamp} [${level}] ${message}" | tee -a "$LOG_FILE"
}

backup_panel() {
    info "Создаю резервную копию..."

    local timestamp=$(date +%Y%m%d_%H%M%S)
    local backup_name="remnawave_backup_${timestamp}"
    local backup_path="${BACKUP_DIR}/${backup_name}"
    mkdir -p "${backup_path}"

    [[ -f "${CONFIG_FILE}" ]] && cp "${CONFIG_FILE}" "${backup_path}/.env"
    [[ -f "${APP_DIR}/docker-compose.yml" ]] && cp "${APP_DIR}/docker-compose.yml" "${backup_path}/docker-compose.yml"

    mkdir -p "${backup_path}/subscription"
    [[ -f "${SUB_DIR}/.env" ]] && cp "${SUB_DIR}/.env" "${backup_path}/subscription/.env"
    [[ -f "${SUB_DIR}/docker-compose.yml" ]] && cp "${SUB_DIR}/docker-compose.yml" "${backup_path}/subscription/docker-compose.yml"

    if [[ -d "${NGINX_DIR}" ]]; then
        mkdir -p "${backup_path}/nginx"
        cp "${NGINX_DIR}/"* "${backup_path}/nginx/" 2>/dev/null || true
    fi

    if [[ -f "/etc/caddy/Caddyfile" ]]; then
        mkdir -p "${backup_path}/caddy"
        cp "/etc/caddy/Caddyfile" "${backup_path}/caddy/Caddyfile" 2>/dev/null || true
    fi

    info "Создаю дамп базы данных..."
    if docker container inspect remnawave-db >/dev/null 2>&1; then
        docker exec remnawave-db pg_dumpall -c -U postgres | gzip -9 > "${backup_path}/database.sql.gz" \
            && info "Дамп базы данных создан" || warn "Не удалось создать дамп базы данных"
    else
        warn "Контейнер remnawave-db не найден"
    fi

    local web_server="nginx"
    [[ -f "/etc/caddy/Caddyfile" ]] && web_server="caddy"
    echo "$web_server" > "${backup_path}/web_server_type"
    grep "^FRONT_END_DOMAIN=" "${APP_DIR}/.env" 2>/dev/null | cut -d= -f2 > "${backup_path}/domain" || true
    grep "^SUB_PUBLIC_DOMAIN=" "${APP_DIR}/.env" 2>/dev/null | cut -d= -f2 > "${backup_path}/sub_domain" || true

    cd "${BACKUP_DIR}"
    tar -czf "${backup_name}.tar.gz" "${backup_name}"
    rm -rf "${backup_name}"

    ls -t "${BACKUP_DIR}"/remnawave_backup_*.tar.gz 2>/dev/null | tail -n +8 | xargs -r rm 2>/dev/null || true

    info "Бэкап успешно создан: ${BACKUP_DIR}/${backup_name}.tar.gz"
    echo "${BACKUP_DIR}/${backup_name}.tar.gz"
}

restore_panel() {
    local backup_file="$1"

    if [[ ! -f "$backup_file" ]]; then
        error "Файл бэкапа не найден: $backup_file"
        return 1
    fi

    info "Восстанавливаю из бэкапа..."

    systemctl stop caddy 2>/dev/null || true
    cd "$NGINX_DIR" 2>/dev/null && docker compose down 2>/dev/null || true
    cd "$SUB_DIR" 2>/dev/null && docker compose down 2>/dev/null || true
    cd "$APP_DIR" 2>/dev/null && docker compose down 2>/dev/null || true

    local temp_dir=$(mktemp -d)
    tar -xzf "$backup_file" -C "$temp_dir"

    local backup_dir=$(find "$temp_dir" -maxdepth 1 -type d -name "remnawave_backup_*" | head -1)
    if [[ -z "$backup_dir" ]]; then
        error "Неверная структура бэкапа"
        rm -rf "$temp_dir"
        return 1
    fi

    mkdir -p "$APP_DIR"
    [[ -f "${backup_dir}/.env" ]] && cp "${backup_dir}/.env" "${APP_DIR}/.env"
    [[ -f "${backup_dir}/docker-compose.yml" ]] && cp "${backup_dir}/docker-compose.yml" "${APP_DIR}/docker-compose.yml"

    mkdir -p "$SUB_DIR"
    [[ -f "${backup_dir}/subscription/.env" ]] && cp "${backup_dir}/subscription/.env" "${SUB_DIR}/.env"
    [[ -f "${backup_dir}/subscription/docker-compose.yml" ]] && cp "${backup_dir}/subscription/docker-compose.yml" "${SUB_DIR}/subscription/docker-compose.yml"

    if [[ -d "${backup_dir}/nginx" ]]; then
        mkdir -p "$NGINX_DIR"
        cp -r "${backup_dir}/nginx/"* "$NGINX_DIR/" 2>/dev/null || true
    fi

    if [[ -d "${backup_dir}/caddy" ]]; then
        mkdir -p /etc/caddy
        [[ -f "${backup_dir}/caddy/Caddyfile" ]] && cp "${backup_dir}/caddy/Caddyfile" /etc/caddy/Caddyfile
    fi

    docker network create remnawave-network 2>/dev/null || true

    info "Запускаю backend для восстановления БД..."
    cd "$APP_DIR" && docker compose up -d

    local max_wait=30
    local waited=0
    while ! docker exec remnawave-db pg_isready -q 2>/dev/null && [ $waited -lt $max_wait ]; do
        sleep 1
        ((waited++))
    done

    if [[ -f "${backup_dir}/database.sql.gz" ]]; then
        info "Восстанавливаю базу данных..."
        gunzip < "${backup_dir}/database.sql.gz" | docker exec -i remnawave-db psql -U postgres -d postgres \
            && info "База данных восстановлена" || warn "Ошибка восстановления базы данных"
    elif [[ -f "${backup_dir}/database.sql" ]]; then
        info "Восстанавливаю базу данных..."
        cat "${backup_dir}/database.sql" | docker exec -i remnawave-db psql -U postgres -d postgres \
            && info "База данных восстановлена" || warn "Ошибка восстановления базы данных"
    fi

    cd "$SUB_DIR" && docker compose up -d

    if [[ -f "${NGINX_DIR}/docker-compose.yml" ]]; then
        cd "$NGINX_DIR" && docker compose up -d
    else
        systemctl enable --now caddy 2>/dev/null || true
    fi

    rm -rf "$temp_dir"
    info "Восстановление завершено!"
}

show_status() {
    echo -e "${CYAN}═══════════════════════════════════════${NC}"
    echo -e "${CYAN}   Статус RemnaWave Panel${NC}"
    echo -e "${CYAN}═══════════════════════════════════════${NC}"

    if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "remnawave"; then
        echo -e "Backend:    ${GREEN}Запущен${NC}"
    else
        echo -e "Backend:    ${RED}Остановлен${NC}"
    fi

    if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "remnawave-subscription-page"; then
        echo -e "Subscription: ${GREEN}Запущен${NC}"
    else
        echo -e "Subscription: ${RED}Остановлен${NC}"
    fi

    local backup_count=$(ls -1 "${BACKUP_DIR}"/remnawave_backup_*.tar.gz 2>/dev/null | wc -l)
    echo -e "Бэкапы:     $backup_count"
    echo -e "${CYAN}═══════════════════════════════════════${NC}"
}

show_menu() {
    clear
    echo -e "${BLUE}${BOLD}"
    echo "  ____                                                  "
    echo " |  _ \ ___ _ __ ___  _ __   __ ___      ____ ___   _____ "
    echo " | |_) / _ \ '_ \ _ \| '_ \ / _\` \ \ /\ / / _` \ \ / / _ \\"
    echo " |  _ <  __/ | | | | | | | | (_| |\ V  V / (_| |\ V /  __/"
    echo " |_| \_\___|_| |_| |_|_| |_|\__,_| \_/\_/ \__,_| \_/ \___|"
    echo ""
    echo -e "      ${YELLOW}v3.1.5 — Docker Compose Edition (Stable)${NC}"
    echo -e "${BLUE}======================================================${NC}\n"

    if [[ -f "$CONFIG_FILE" ]]; then
        show_status
    fi

    echo -e "${BLUE}Главное меню:${NC}"
    echo "  1) Создать бэкап"
    echo "  2) Восстановить из бэкапа"
    echo "  3) Показать статус"
    echo "  4) Выход"
    echo ""
    if [ -e /dev/tty ]; then read -rp "Выберите опцию [1-4]: " choice < /dev/tty; else read -p "Выберите опцию [1-4]: " choice; fi

    case $choice in
        1)
            backup_panel
            echo -e "\n${GREEN}Нажмите Enter для продолжения...${NC}"
            read < /dev/tty
            show_menu
            ;;
        2)
            echo "Доступные бэкапы:"
            ls -lh "${BACKUP_DIR}"/remnawave_backup_*.tar.gz 2>/dev/null || echo "Бэкапы не найдены"
            echo ""
            read -rp "Путь к бэкапу: " backup_file < /dev/tty
            restore_panel "$backup_file"
            echo -e "\n${GREEN}Нажмите Enter для продолжения...${NC}"
            read < /dev/tty
            show_menu
            ;;
        3)
            show_status
            echo -e "\n${GREEN}Нажмите Enter для продолжения...${NC}"
            read < /dev/tty
            show_menu
            ;;
        4)
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

main() {
    if [[ $EUID -ne 0 ]]; then
        echo "Скрипт нужно запускать от root"
        exit 1
    fi
    mkdir -p "$(dirname "$LOG_FILE")"
    > "$LOG_FILE"
    show_menu
}

main "$@"