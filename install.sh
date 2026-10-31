#!/bin/bash

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
PURPLE='\033[0;35m'
BOLD='\033[1m'
NC='\033[0m'

APP_DIR="/opt/remnawave"
NGINX_DIR="/nginx"
SUB_DIR="/subscription"
BACKUP_DIR="/backups"
LOG_FILE="/var/log/remnawave_install.log"
CONFIG_FILE="/.env"

info() { echo -e "[✓] $1"; log "INFO" "$1"; }
warn() { echo -e "[!] $1"; log "WARN" "$1"; }
error() { echo -e "[✗] $1"; log "ERROR" "$1"; }

log() {
    local level="$1"
    local message="$2"
    local timestamp=
    echo -e " [] " | tee -a ""
}

backup_panel() {
    info "Создаю резервную копию..."

    local timestamp=
    local backup_name="remnawave_backup_"
    local backup_path="/"
    mkdir -p ""

    [[ -f "" ]] && cp "" "/.env"
    [[ -f "/docker-compose.yml" ]] && cp "/docker-compose.yml" "/docker-compose.yml"

    mkdir -p "/subscription"
    [[ -f "/.env" ]] && cp "/.env" "/subscription/.env"
    [[ -f "/docker-compose.yml" ]] && cp "/docker-compose.yml" "/subscription/docker-compose.yml"

    if [[ -d "" ]]; then
        mkdir -p "/nginx"
        cp "/"* "/nginx/" 2>/dev/null || true
    fi

    if [[ -f "/etc/caddy/Caddyfile" ]]; then
        mkdir -p "/caddy"
        cp "/etc/caddy/Caddyfile" "/caddy/Caddyfile" 2>/dev/null || true
    fi

    info "Создаю дамп базы данных..."
    if docker container inspect remnawave-db >/dev/null 2>&1; then
        docker exec remnawave-db pg_dumpall -c -U postgres | gzip -9 > "/database.sql.gz" \
            && info "Дамп базы данных создан" || warn "Не удалось создать дамп базы данных"
    else
        warn "Контейнер remnawave-db не найден"
    fi

    local web_server="nginx"
    [[ -f "/etc/caddy/Caddyfile" ]] && web_server="caddy"
    echo "$web_server" > "/web_server_type"
    grep "^FRONT_END_DOMAIN=" "/.env" 2>/dev/null | cut -d= -f2 > "/domain" || true
    grep "^SUB_PUBLIC_DOMAIN=" "/.env" 2>/dev/null | cut -d= -f2 > "/sub_domain" || true

    cd ""
    tar -czf ".tar.gz" ""
    rm -rf ""

    ls -t ""/remnawave_backup_*.tar.gz 2>/dev/null | tail -n +8 | xargs -r rm 2>/dev/null || true

    info "Бэкап успешно создан: /.tar.gz"
    echo "/.tar.gz"
}

restore_panel() {
    local backup_file="$1"

    if [[ ! -f "$backup_file" ]]; then
        error "Файл бэкапа не найден: $backup_file"
        return 1
    fi

    info "Восстанавливаю из бэкапа..."

    systemctl stop caddy 2>/dev/null || true
    cd "" 2>/dev/null && docker compose down 2>/dev/null || true
    cd "" 2>/dev/null && docker compose down 2>/dev/null || true
    cd "" 2>/dev/null && docker compose down 2>/dev/null || true

    local temp_dir=
    tar -xzf "$backup_file" -C "$temp_dir"

    local backup_dir=
    if [[ -z "$backup_dir" ]]; then
        error "Неверная структура бэкапа"
        rm -rf "$temp_dir"
        return 1
    fi

    mkdir -p ""
    [[ -f "$backup_dir/.env" ]] && cp "$backup_dir/.env" "/.env"
    [[ -f "$backup_dir/docker-compose.yml" ]] && cp "$backup_dir/docker-compose.yml" "/docker-compose.yml"

    mkdir -p ""
    [[ -f "$backup_dir/subscription/.env" ]] && cp "$backup_dir/subscription/.env" "/.env"
    [[ -f "$backup_dir/subscription/docker-compose.yml" ]] && cp "$backup_dir/subscription/docker-compose.yml" "/docker-compose.yml"

    if [[ -d "$backup_dir/nginx" ]]; then
        mkdir -p ""
        cp -r "$backup_dir/nginx/"* "/" 2>/dev/null || true
    fi

    if [[ -d "$backup_dir/caddy" ]]; then
        mkdir -p /etc/caddy
        [[ -f "$backup_dir/caddy/Caddyfile" ]] && cp "$backup_dir/caddy/Caddyfile" /etc/caddy/Caddyfile
    fi

    docker network create remnawave-network 2>/dev/null || true

    info "Запускаю backend для восстановления БД..."
    cd "" && docker compose up -d

    local max_wait=30
    local waited=0
    while ! docker exec remnawave-db pg_isready -q 2>/dev/null && [ $waited -lt $max_wait ]; do
        sleep 1
        ((waited++))
    done

    if [[ -f "$backup_dir/database.sql.gz" ]]; then
        info "Восстанавливаю базу данных..."
        gunzip < "$backup_dir/database.sql.gz" | docker exec -i remnawave-db psql -U postgres -d postgres \
            && info "База данных восстановлена" || warn "Ошибка восстановления базы данных"
    elif [[ -f "$backup_dir/database.sql" ]]; then
        info "Восстанавливаю базу данных..."
        cat "$backup_dir/database.sql" | docker exec -i remnawave-db psql -U postgres -d postgres \
            && info "База данных восстановлена" || warn "Ошибка восстановления базы данных"
    fi

    cd "" && docker compose up -d

    if [[ -f "/docker-compose.yml" ]]; then
        cd "" && docker compose up -d
    else
        systemctl enable --now caddy 2>/dev/null || true
    fi

    rm -rf "$temp_dir"
    info "Восстановление завершено!"
}

show_status() {
    echo -e "═══════════════════════════════════════"
    echo -e "   Статус RemnaWave Panel"
    echo -e "═══════════════════════════════════════"

    if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "remnawave"; then
        echo -e "Backend:    Запущен"
    else
        echo -e "Backend:    Остановлен"
    fi

    if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "remnawave-subscription-page"; then
        echo -e "Subscription: Запущен"
    else
        echo -e "Subscription: Остановлен"
    fi

    local backup_count=
    echo -e "Бэкапы:     $backup_count"
    echo -e "═══════════════════════════════════════"
}

show_menu() {
    clear
    echo -e ""
    echo "  ____                                                  "
    echo " |  _ \ ___ _ __ ___  _ __   __ ___      ____ ___   _____ "
    echo " | |_) / _ \ '_ \ _ \| '_ \ / _\ \ \ /\ / / _\ \ \ / / _ \\"
    echo " |  _ <  __/ | | | | | | | | (_| |\ V  V / (_| |\ V /  __/"
    echo " |_| \_\___|_| |_| |_|_| |_|\__,_| \_/\_/ \__,_| \_/ \___|"
    echo ""
    echo -e "      v3.1.5 — Docker Compose Edition (Stable)"
    echo -e "======================================================\n"

    if [[ -f "" ]]; then
        show_status
    fi

    echo -e "Главное меню:"
    echo "  1) Создать бэкап"
    echo "  2) Восстановить из бэкапа"
    echo "  3) Показать статус"
    echo "  4) Выход"
    echo ""
    read -rp "Выберите опцию [1-4]: " choice < /dev/tty

    case $choice in
        1)
            backup_panel
            echo -e "\nНажмите Enter для продолжения..."
            read < /dev/tty
            show_menu
            ;;
        2)
            echo "Доступные бэкапы:"
            ls -lh ""/remnawave_backup_*.tar.gz 2>/dev/null || echo "Бэкапы не найдены"
            echo ""
            read -rp "Путь к бэкапу: " backup_file < /dev/tty
            restore_panel "$backup_file"
            echo -e "\nНажмите Enter для продолжения..."
            read < /dev/tty
            show_menu
            ;;
        3)
            show_status
            echo -e "\nНажмите Enter для продолжения..."
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
    mkdir -p ""
    > ""
    show_menu
}

main "$@"