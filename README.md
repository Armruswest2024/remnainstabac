# RemnaWave Panel Installer

Скрипт автоматической установки, бэкапа, восстановления и миграции панели RemnaWave для Debian/Ubuntu серверов.

**Версия:** 3.1.0 (Docker Compose Edition)

## Возможности

### Установка
- Полная установка RemnaWave через Docker Compose
- Backend + PostgreSQL в одном контейнере
- Subscription page (страница подписки)
- SSL-сертификаты через acme.sh (Let's Encrypt)
- Выбор веб-сервера: **Nginx** (Docker) или **Caddy** (автоматический SSL)
- Автоматические бэкапы по cron (ежедневно в 03:00)
- Health check после установки/обновления

### Бэкап
Автоматическое создание резервной копии **всех** данных:
- `.env` — пароли, JWT-секреты, URL базы данных
- `docker-compose.yml` — конфигурация backend
- SSL-сертификаты (fullchain.pem, privkey.key)
- Конфигурация Nginx (nginx.conf)
- Subscription page (API-токен, docker-compose.yml)
- Конфигурация Caddy (если используется)
- **Dump PostgreSQL** (база данных)
- Автобэкап по cron (ежедневно в 03:00, хранит 7 последних копий)

### Восстановление
Восстановление из бэкапа на **тот же** или **другой** сервер:
- Выбор: оставить домен из бэкапа или указать новый
- Выбор: оставить веб-сервер или сменить (Nginx ↔ Caddy)
- Автоматическое получение новых SSL-сертификатов при смене домена
- Восстановление базы данных из dump
- Автоматическая перелинковка подписки при смене домена

### Миграция
Перенос панели с одного сервера на другой через SSH:
- Копирование бэкапа по SSH
- Восстановление на новом сервере
- Опциональная смена домена
- Опциональная смена веб-сервера (Nginx ↔ Caddy)
- Автоматическая генерация SSH-ключа (если нет)

### Управление
- Обновление панели (docker compose pull) + очистка старых образов
- Удаление панели (с подтверждением)
- Просмотр статуса (контейнеры, домен, бэкапы)
- Health check всех сервисов

## Требования

- **ОС:** Debian 10+ / Ubuntu 20.04+
- **RAM:** минимум 1GB (рекомендуется 2GB+)
- **Диск:** минимум 5GB свободного места
- **Доступ:** root (или sudo)
- **Порты:** 80 и 443 (должны быть свободны)
- **Сеть:** доступ к интернету

## Установка

### Одной командой (для ленивых)

```bash
bash <(wget -qO- https://raw.githubusercontent.com/Armruswest2024/remnainstabac/refs/heads/main/install.sh)
```

Или через curl:

```bash
curl -sL https://raw.githubusercontent.com/Armruswest2024/remnainstabac/refs/heads/main/install.sh | bash
```

### Пошагово

```bash
# Скачать скрипт
wget -O install.sh https://raw.githubusercontent.com/Armruswest2024/remnainstabac/refs/heads/main/install.sh

# Сделать исполняемым
chmod +x install.sh

# Запустить от root
sudo ./install.sh
```

## Меню

```
╔════════════════════════════════════════╗
║   RemnaWave Panel Installer v3.0.0    ║
╚════════════════════════════════════════╝

Главное меню:
  1) Чистая установка
  2) Миграция (с другого сервера)
  3) Создать бэкап
  4) Восстановить из бэкапа
  5) Обновить панель
  6) Удалить панель
  7) Показать статус
  8) Выход
```

## Структура файлов

```
/opt/remnawave/
├── docker-compose.yml      # Backend (RemnaWave + PostgreSQL)
├── .env                    # Конфигурация (пароли, JWT, DB_URL)
├── nginx/
│   ├── docker-compose.yml  # Nginx контейнер
│   ├── nginx.conf          # Конфигурация Nginx
│   ├── fullchain.pem       # SSL для панели
│   ├── privkey.key
│   ├── subdomain_fullchain.pem  # SSL для подписки
│   └── subdomain_privkey.key
└── subscription/
    ├── docker-compose.yml  # Subscription page
    └── .env                # API-токен подписки
```

## Бэкап

Бэкап создаёт архив со всеми файлами:

```
remnawave_backup_20260629_120000.tar.gz
├── .env                    # Все пароли и секреты
├── docker-compose.yml      # Backend конфиг
├── nginx/
│   ├── nginx.conf
│   ├── docker-compose.yml
│   ├── fullchain.pem       # SSL сертификаты
│   ├── privkey.key
│   ├── subdomain_fullchain.pem
│   └── subdomain_privkey.key
├── subscription/
│   ├── .env
│   └── docker-compose.yml
├── caddy/                  # Если Caddy
│   └── Caddyfile
├── web_server_type         # Метаданные
├── domain
└── sub_domain
```

## Миграция

### Сценарий 1: Тот же домен
1. Запустите скрипт на новом сервере
2. Выберите "Миграция"
3. Укажите IP старого сервера
4. Выберите "Не менять домен"
5. Скрипт скопирует бэкап и восстановит всё

### Сценарий 2: Новый домен
1. Запустите скрипт на новом сервере
2. Выберите "Миграция"
3. Укажите IP старого сервера
4. Выберите "Изменить домен"
5. Введите новый домен и email
6. Скрипт получит новые SSL-сертификаты

### Сценарий 3: Смена веб-сервера
1. При миграции выберите другой веб-сервер
2. Скрипт автоматически сконвертирует конфигурацию

## Полезные команды

```bash
# Статус контейнеров
cd /opt/remnawave && docker compose ps

# Логи backend
docker logs remnawave

# Логи подписки
docker logs remnawave-subscription-page

# Ручной бэкап
/opt/remnawave/scripts/backup.sh

# Просмотр логов установки
tail -f /var/log/remnawave_install.log
```

## Обновление

```bash
# Через меню скрипта
sudo ./install.sh
# Выберите "Обновить панель"

# Или вручную
cd /opt/remnawave
docker compose down
docker compose pull
docker compose up -d
```

## Удаление

```bash
# Через меню скрипта
sudo ./install.sh
# Выберите "Удалить панель"
# Подтвердите ввод "yes"
```

## Решение проблем

### Порт 80/443 занят
```bash
ss -tlnp | grep :80
ss -tlnp | grep :443
systemctl stop apache2  # или другой веб-сервер
```

### SSL-сертификат не получен
```bash
# Проверьте DNS
dig panel.example.com

# Проверьте доступность порта 80
curl -I http://panel.example.com
```

### Контейнер не запускается
```bash
# Проверьте логи
docker logs remnawave
docker logs remnawave-nginx

# Перезапустите
cd /opt/remnawave && docker compose restart
```

## Лицензия

Скрипт распространяется под лицензией MIT.
