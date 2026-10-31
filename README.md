# RemnaWave Panel Backup & Restore

Скрипт резервного копирования и восстановления панели RemnaWave для Debian/Ubuntu серверов.

**Версия:** 3.1.5 (Stable)

## Возможности

### Бэкап
Полное резервное копирование:
- `.env` — пароли, секреты, конфигурация
- `docker-compose.yml` — конфигурация контейнеров
- SSL-сертификаты (fullchain.pem, privkey.key)
- Nginx конфигурация (nginx.conf)
- Subscription page (API-токен, docker-compose.yml)
- **Сжатый дамп PostgreSQL** через `pg_dumpall`
- Метаданные: домен, тип веб-сервера
- Всё упаковывается в `.tar.gz` архив

### Восстановление
Восстановление из бэкапа на **тот же или другой сервер**:
- Автоматический даун контнейнеров
- Распаковка файлов из архива
- Восстановление базы данных из `.sql.gz` дампа
- Поднятие сервисов в правильном порядке

## Требования

- **ОС:** Debian 10+ / Ubuntu 20.04+
- **Доступ:** root
- **Docker:** установлен и работает
- **Контейнер БД:** `remnawave-db` (стандартный из docker-compose)

## Установка и запуск

```bash
curl -sL https://raw.githubusercontent.com/Armruswest2024/remnainstabac/main/install.sh | bash
```

## Меню

```
======================================================
       REMNAWAVE PANEL - BACKUP & RESTORE
======================================================

Backend:    Запущен
Subscription: Запущен
Бэкапы:     0

Main Menu:
  1) Create Backup
  2) Restore from Backup
  3) Show Status
  4) Exit
```

## Перенос между серверами

Скрипт создаёт полный бэкап, который можно перенести вручную:

```bash
# 1. Создать бэкап на старом сервере
curl -sL https://raw.githubusercontent.com/Armruswest2024/remnainstabac/main/install.sh | bash
# Выбрать пункт 1) Create Backup

# 2. Скопировать бэкап на новый сервер
# Стандартный порт 22:
scp /opt/remnawave/backups/remnawave_backup_*.tar.gz root@новый-сервер:/tmp/
# Если порт другой, например 2222:
scp -P 2222 /opt/remnawave/backups/remnawave_backup_*.tar.gz root@новый-сервер:/tmp/

# 3. Восстановить на новом сервере
curl -sL https://raw.githubusercontent.com/Armruswest2024/remnainstabac/main/install.sh | bash
# Выбрать пункт 2) Restore from Backup, указать путь к файлу
```

## Структура файлов

```
/opt/remnawave/
├── docker-compose.yml      # Backend (RemnaWave + PostgreSQL + Valkey)
├── .env                    # Конфигурация (пароли, секреты, URL)
├── nginx/
│   ├── docker-compose.yml  # Nginx контейнер
│   ├── nginx.conf          # Конфигурация Nginx
│   ├── fullchain.pem       # SSL для панели
│   ├── privkey.key
│   ├── subdomain_fullchain.pem  # SSL для подписки
│   └── subdomain_privkey.key
├── subscription/
│   ├── docker-compose.yml  # Subscription page
│   └── .env                # API-токен подписки
└── backups/
    └── remnawave_backup_YYYYMMDD_HHMMSS.tar.gz
```

## Примечания

- Бэкап создаётся в `/opt/remnawave/backups/`
- Хранится 7 последних копий, старые удаляются автоматически
- Дамп базы сжимается через `gzip -9`
- Для восстановления нужен полный архив с файлами `database.sql.gz` и конфигами
