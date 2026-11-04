#!/bin/bash

#####################################################
# Скрипт автоматической настройки Remnawave Node
# Версия: 4.0.0
#
# Новое в v4.0:
#   - Роли нод (NODE_ROLE): entry, exit, exit-direct. Роль задаёт
#     nginx, сертификаты, монтирования remnanode и правила UFW
#   - Единые пути и имена контейнеров на всех серверах:
#     /opt/remnanode, /opt/nginx, /opt/certs, /opt/certwarden-client
#   - Сертификаты: CertWarden-клиент или файлы, положенные вручную
#   - Режим --role-only: только ролевая часть на настроенном сервере
#   - Версия образа remnawave/node фиксируется (REMNANODE_VERSION)
#   - XRAY_PORT удалён: нода такую переменную не читает, порты
#     Xray задаются профилем в панели, правила UFW — ролью
#   - Итоговая проверка с отчётом ✓ / ✗ и подсказкой для панели
#   - Конфиги перед заменой сохраняются в /opt/<компонент>/backup-<дата>/
#
# Исправления в v3.2.1:
#   - Установка больше не требует wget: загрузчик выбирается по
#     факту наличия (curl или wget), недостающий доустанавливается
#   - Зависимости проверяются заранее, а не в момент загрузки
#   - Вывод загрузчика не подавляется — причина сбоя попадает в лог
#
# Новое в v3.2:
#   - Неинтерактивный режим: параметры читаются из .env-файла
#     и/или переменных окружения
#   - Флаги --config, --non-interactive, --no-save-env, --help
#   - Ответы интерактивного режима сохраняются в .env (chmod 600),
#     повторная установка проходит без вопросов
#
# Исправления в v3.1:
#   - UFW больше не отрезает SSH на нестандартном порту:
#     порты определяются автоматически и подтверждаются
#   - NODE_PORT разрешается с NetBird IP панели, а не с
#     публичного (панель ходит к ноде через mesh-сеть)
#   - Детект APT-блокировки работает без пакета psmisc
#   - Устойчивое определение версий бинарников мониторинга
#   - Исправлен разбор статусов параллельных загрузок
#   - Понятная ошибка при запуске без root
#
# Улучшения v3.0 по сравнению с v2.1:
#   - Параллельная загрузка бинарников мониторинга
#   - Автоопределение архитектуры (amd64/arm64)
#   - Исправлена индентация YAML-конфигов
#   - Проверка версий при повторном запуске (idempotency)
#   - Генерация docker-compose.yml по шаблону
#   - UFW открывает XRAY_PORT для TCP и UDP
#   - Улучшена обработка ошибок (set -e + grep)
#   - Таймаут на загрузки (wget --timeout)
#   - Валидация IP-адресов
#
# Запуск:
#   curl ... | sudo bash
#   curl -fsSL -o setup_remnawave_node.sh <url> && sudo bash setup_remnawave_node.sh
#   (не sudo bash <(curl ...): под sudo подстановка процесса не работает)
#####################################################

set -euo pipefail
# set -e  — остановка при ошибке
# set -u  — остановка при использовании неустановленной переменной
# set -o pipefail — ошибка в pipe'е передаётся наружу

# ─────────────────────────────────────────────────
# Цвета для вывода
# ─────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# ─────────────────────────────────────────────────
# Пути и файлы
# ─────────────────────────────────────────────────
PROJECT_DIR="/opt/remnanode"
MONITORING_DIR="/opt/monitoring"
LOG_FILE="/var/log/remnawave_setup.log"

# Ролевые компоненты. Пути и имена контейнеров одинаковы на всех
# серверах: на них завязаны CertWarden-клиент (кого перезапускать
# после продления) и профили в панели (где лежит сертификат).
#
# Правило для всех compose-файлов: никаких ports: на 0.0.0.0.
# Опубликованные Docker порты идут через iptables мимо UFW и были бы
# открыты всему интернету. Только network_mode: host (тогда порты
# закрывает UFW) или публикация на 127.0.0.1.
NGINX_DIR="/opt/nginx"
CERTS_DIR="/opt/certs"
CERTWARDEN_DIR="/opt/certwarden-client"
CERT_FULLCHAIN="fullchain.pem"
CERT_PRIVKEY="privkey.key"

# Куда сертификат монтируется в remnanode (роль exit-direct):
# по этому пути профиль Hysteria2 в панели ищет fullchain.pem и privkey.key
REMNANODE_SSL_DIR="/var/lib/remnawave/configs/xray/ssl"

# Образы ролевых компонентов — только точные теги, чтобы на всех
# серверах стояло одно и то же. nginx — стабильная ветка (stable-alpine).
# certwarden-client v0.5.0: начиная с этой версии клиент понимает
# CW_CLIENT_CERTCHAIN_PEM_FILENAME / CW_CLIENT_KEY_PEM_FILENAME;
# v0.4.0 всегда пишет certchain.pem и key.pem
NGINX_IMAGE="nginx:1.30.6-alpine"
CERTWARDEN_IMAGE="ghcr.io/gregtwallace/certwarden-client:v0.5.0"

# Откуда брать шаблоны, если скрипт запущен не из клона репозитория
# (curl ... | bash). Ветку можно переопределить для проверки
# неслитых изменений: REMNAWAVE_INSTALLER_REF=dev
INSTALLER_REF="${REMNAWAVE_INSTALLER_REF:-main}"
TEMPLATES_URL="https://raw.githubusercontent.com/VAQYBIN/Remnawave-Node-Auto-Installer/${INSTALLER_REF}/templates"

# Метка для резервных копий конфигов — одна на весь запуск
BACKUP_STAMP="$(date +%Y%m%d-%H%M%S)"

# Временная директория для параллельных загрузок и шаблонов.
# Создаётся в init_tmp_dir через mktemp: предсказуемое имя вида
# /tmp/remnawave_setup_$$ мог бы заранее создать другой пользователь
# и подменить скачанные бинарники или шаблоны до того, как root их
# установит.
TMP_DIR=""
TEMPLATE_CACHE=""

# ─────────────────────────────────────────────────
# Версии компонентов мониторинга
# Чтобы обновить — просто измените цифры здесь
# ─────────────────────────────────────────────────
CADVISOR_VERSION="0.55.1"
NODE_EXPORTER_VERSION="1.9.1"
VMAGENT_VERSION="1.123.0"

# ─────────────────────────────────────────────────
# Параметры установки
#
# Каждый параметр инициализируется как "${VAR:-}", а не пустой
# строкой: это сохраняет значение, переданное через окружение.
# Простое VAR="" затёрло бы его, и режим
#   sudo NETBIRD_SETUP_KEY=xxx bash setup_remnawave_node.sh
# перестал бы работать.
#
# Источники значений, в порядке убывания приоритета:
#   1. переменная окружения
#   2. файл конфигурации (.env)
#   3. значение по умолчанию
#   4. интерактивный вопрос
# ─────────────────────────────────────────────────
NETBIRD_SETUP_KEY="${NETBIRD_SETUP_KEY:-}"
INSTANCE_NAME="${INSTANCE_NAME:-}"
VICTORIA_METRICS_URL="${VICTORIA_METRICS_URL:-}"
NODE_PORT="${NODE_PORT:-}"
PANEL_NETBIRD_IP="${PANEL_NETBIRD_IP:-}"   # NetBird IP панели (100.x.x.x), а не публичный
SSH_PORTS="${SSH_PORTS:-}"                 # строка "22 2233"; пусто — автоопределение
SECRET_KEY="${SECRET_KEY:-}"               # выдаётся панелью при создании ноды

# Роль ноды и её параметры
NODE_ROLE="${NODE_ROLE:-}"                 # entry | exit | exit-direct
NODE_DOMAIN="${NODE_DOMAIN:-}"             # entry, exit-direct
CERT_SOURCE="${CERT_SOURCE:-}"             # certwarden | manual
REMNANODE_VERSION="${REMNANODE_VERSION:-}" # тег образа remnawave/node
XRAY_LOCAL_PORT="${XRAY_LOCAL_PORT:-}"     # entry: Reality-инбаунд на 127.0.0.1
SITE_LOCAL_PORT="${SITE_LOCAL_PORT:-}"     # entry, exit-direct: сайт на 127.0.0.1

# Параметры CertWarden-клиента. Имена совпадают с переменными
# окружения самого клиента и передаются ему как есть.
CW_CLIENT_SERVER_ADDRESS="${CW_CLIENT_SERVER_ADDRESS:-}"
CW_CLIENT_AES_KEY_BASE64="${CW_CLIENT_AES_KEY_BASE64:-}"
CW_CLIENT_KEY_NAME="${CW_CLIENT_KEY_NAME:-}"
CW_CLIENT_KEY_APIKEY="${CW_CLIENT_KEY_APIKEY:-}"
CW_CLIENT_CERT_NAME="${CW_CLIENT_CERT_NAME:-}"
CW_CLIENT_CERT_APIKEY="${CW_CLIENT_CERT_APIKEY:-}"
CW_CLIENT_FILE_UPDATE_TIME_START="${CW_CLIENT_FILE_UPDATE_TIME_START:-}"
CW_CLIENT_FILE_UPDATE_TIME_END="${CW_CLIENT_FILE_UPDATE_TIME_END:-}"
CW_CLIENT_FILE_UPDATE_DAYS_OF_WEEK="${CW_CLIENT_FILE_UPDATE_DAYS_OF_WEEK:-}"
TZ="${TZ:-}"                               # часовой пояс окна обновления файлов

# Значения по умолчанию для необязательных параметров
DEFAULT_NODE_PORT="2222"
DEFAULT_REMNANODE_VERSION="3.4.4"
DEFAULT_XRAY_LOCAL_PORT="10443"
DEFAULT_SITE_LOCAL_PORT="9443"
DEFAULT_CW_TIME_START="02:00"
DEFAULT_CW_TIME_END="03:00"
DEFAULT_CW_DAYS="Mon Tue Wed Thu Fri Sat Sun"
DEFAULT_TZ="Europe/Moscow"

# Порт моста (инбаунд bridge-in на выходах). Работает только через
# NetBird, в UFW не открывается ни в одной роли.
BRIDGE_PORT="10443"

# Вычисляются в процессе работы
NETBIRD_IP=""
NETBIRD_FQDN=""
ARCH_SUFFIX=""        # Определяется автоматически
SSH_PORT_LIST=()      # Итоговый список портов для правил UFW
DOWNLOADER=""         # "curl" или "wget" — выбирается по факту наличия
NGINX_CONF_CHANGED=0  # nginx.conf изменился — нужен reload

# ─────────────────────────────────────────────────
# Режим работы
# ─────────────────────────────────────────────────
ENV_FILE="${REMNAWAVE_ENV_FILE:-/opt/remnawave-installer/.env}"
NON_INTERACTIVE=0
SAVE_ENV=1
ROLE_ONLY=0           # --role-only: без системы, NetBird, Docker, мониторинга

# Белый список параметров, распознаваемых в файле конфигурации.
# Всё остальное игнорируется с предупреждением — это ловит опечатки
# и не даёт файлу конфигурации переопределить внутренние переменные
# скрипта (пути, версии компонентов, режим работы).
ENV_KEYS=(
    NETBIRD_SETUP_KEY
    INSTANCE_NAME
    VICTORIA_METRICS_URL
    NODE_PORT
    PANEL_NETBIRD_IP
    SSH_PORTS
    SECRET_KEY
    NODE_ROLE
    NODE_DOMAIN
    CERT_SOURCE
    REMNANODE_VERSION
    XRAY_LOCAL_PORT
    SITE_LOCAL_PORT
    CW_CLIENT_SERVER_ADDRESS
    CW_CLIENT_AES_KEY_BASE64
    CW_CLIENT_KEY_NAME
    CW_CLIENT_KEY_APIKEY
    CW_CLIENT_CERT_NAME
    CW_CLIENT_CERT_APIKEY
    CW_CLIENT_FILE_UPDATE_TIME_START
    CW_CLIENT_FILE_UPDATE_TIME_END
    CW_CLIENT_FILE_UPDATE_DAYS_OF_WEEK
    TZ
)

# Параметры прошлых версий: в файле конфигурации не считаются
# опечаткой, но игнорируются с пояснением
DEPRECATED_ENV_KEYS=(
    XRAY_PORT   # v3: нода его не читает, UFW теперь задаёт роль
)

# Метод проверки APT-блокировки: "fuser" или "proc".
# Выбирается один раз при первом обращении.
LOCK_CHECK_METHOD=""

# ─────────────────────────────────────────────────
# Функции логирования
# ─────────────────────────────────────────────────
log() {
    echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $1" | tee -a "$LOG_FILE"
}

log_error() {
    echo -e "${RED}[$(date +'%Y-%m-%d %H:%M:%S')] ERROR:${NC} $1" | tee -a "$LOG_FILE"
}

log_warning() {
    echo -e "${YELLOW}[$(date +'%Y-%m-%d %H:%M:%S')] WARNING:${NC} $1" | tee -a "$LOG_FILE"
}

log_info() {
    echo -e "${BLUE}[$(date +'%Y-%m-%d %H:%M:%S')] INFO:${NC} $1" | tee -a "$LOG_FILE"
}

# ─────────────────────────────────────────────────
# Очистка временных файлов при выходе
# ─────────────────────────────────────────────────
cleanup() {
    [[ -n "$TMP_DIR" ]] && rm -rf "$TMP_DIR"
    return 0
}
trap cleanup EXIT

# ─────────────────────────────────────────────────
# Создание временной директории
#
# mktemp -d создаёт новый каталог с уникальным именем и правами 700,
# поэтому заранее подготовить или подменить его никто не может.
# ─────────────────────────────────────────────────
init_tmp_dir() {
    if ! TMP_DIR=$(mktemp -d /tmp/remnawave_setup.XXXXXXXX); then
        log_error "Не удалось создать временную директорию в /tmp"
        exit 1
    fi
    TEMPLATE_CACHE="$TMP_DIR/templates"
}

# ─────────────────────────────────────────────────
# Справка по использованию
# ─────────────────────────────────────────────────
usage() {
    cat <<'USAGE'
Remnawave Node Auto-Installer

Использование:
  curl -fsSL -o setup_remnawave_node.sh git.new/remnawave-setup
  sudo bash setup_remnawave_node.sh [ОПЦИИ]

  Не запускайте через sudo bash <(curl ...): под sudo подстановка
  процесса не работает (на Ubuntu 26.04 с sudo-rs — никогда)

Опции:
  -c, --config PATH     Путь к файлу конфигурации
                        (по умолчанию: /opt/remnawave-installer/.env)
  -n, --non-interactive Не задавать вопросов. При нехватке обязательных
                        параметров скрипт завершится с ошибкой
      --role-only       Только ролевая часть: nginx, сертификаты,
                        remnanode, UFW. Без обновления системы, NetBird,
                        Docker и мониторинга — для приведения к стандарту
                        уже настроенных нод. NetBird и Docker должны
                        быть установлены
      --no-save-env     Не сохранять введённые ответы в файл конфигурации
  -h, --help            Показать эту справку

Роли (NODE_ROLE):

  entry        Входная нода (РФ). nginx принимает 443/tcp и разводит
               по SNI: NODE_DOMAIN → Xray (127.0.0.1:XRAY_LOCAL_PORT),
               остальное → сайт-заглушка (127.0.0.1:SITE_LOCAL_PORT).
               Сертификат нужен. Открыто для всех: 443/tcp, 80/tcp

  exit         Выходная нода. Трафик приходит с входных нод по NetBird.
               Без nginx и сертификата. Открытых для всех портов нет

  exit-direct  Выходная нода с прямыми подключениями и Hysteria2.
               443 слушает Xray, nginx держит только сайт-заглушку.
               Сертификат монтируется в remnanode. Открыто для всех:
               443/tcp, 443/udp, 8443/tcp, 80/tcp

  Порт моста 10443/tcp не открывается ни в одной роли: мост
  работает через NetBird.

Параметры конфигурации (файл .env или переменные окружения):

  Обязательные:
    NODE_ROLE             entry | exit | exit-direct
    PANEL_NETBIRD_IP      NetBird IP панели Remnawave (100.x.x.x)
    NETBIRD_SETUP_KEY     Ключ из панели app.netbird.io  ┐ не нужны
    INSTANCE_NAME         Имя ноды для метрик            │ с --role-only
    VICTORIA_METRICS_URL  IP или URL Victoria Metrics    ┘

  Для ролей entry и exit-direct:
    NODE_DOMAIN           Домен ноды, например ru03.example.org
    CERT_SOURCE           certwarden | manual
                          manual: fullchain.pem и privkey.key заранее
                          положить в /opt/certs
    CW_CLIENT_*, TZ       Параметры CertWarden-клиента (CERT_SOURCE=
                          certwarden), см. .env.example

  Необязательные:
    NODE_PORT             Порт для связи с панелью (по умолчанию 2222)
    REMNANODE_VERSION     Тег образа remnawave/node (по умолчанию 3.4.4)
    XRAY_LOCAL_PORT       entry: порт Reality на 127.0.0.1 (по умолчанию 10443)
    SITE_LOCAL_PORT       Порт сайта-заглушки на 127.0.0.1 (по умолчанию 9443)
    SSH_PORTS             Порты SSH через пробел, например "22 2233".
                          Если не задан — определяются автоматически
    SECRET_KEY            Ключ ноды из панели. Если не задан, в
                          docker-compose.yml пишется плейсхолдер
                          (или сохраняется ключ из существующего файла)

Приоритет источников: переменная окружения → файл конфигурации →
значение по умолчанию → интерактивный вопрос.

Единые пути:
  /opt/remnanode/docker-compose.yml        контейнер remnanode
  /opt/nginx/{nginx.conf,html/,docker-compose.yml}   контейнер nginx
  /opt/certs/{fullchain.pem,privkey.key}   сертификат
  /opt/certwarden-client/docker-compose.yml   контейнер certwarden-client
  Заменяемые конфиги сохраняются в /opt/<компонент>/backup-<дата>/

Примеры:
  # Обычная интерактивная установка; ответы сохранятся в .env
  sudo bash setup_remnawave_node.sh

  # Полностью автоматическая установка из файла
  sudo bash setup_remnawave_node.sh --config /root/node.conf --non-interactive

  # Привести существующую ноду к стандарту роли
  sudo bash setup_remnawave_node.sh --role-only --config /root/node.conf

  # Общие параметры в файле, уникальные — через окружение
  sudo INSTANCE_NAME=de-node-02 SECRET_KEY=xxx \
       bash setup_remnawave_node.sh --non-interactive

Важно: переменные указывайте ПОСЛЕ sudo. Запись вида
"VAR=x sudo bash script.sh" не сработает — sudo очищает окружение.
USAGE
}

# ─────────────────────────────────────────────────
# Разбор аргументов командной строки
# ─────────────────────────────────────────────────
parse_args() {
    while (( $# > 0 )); do
        case "$1" in
            -c|--config)
                if [[ -z "${2:-}" ]]; then
                    echo "Ошибка: $1 требует указания пути" >&2
                    exit 1
                fi
                ENV_FILE="$2"
                shift 2
                ;;
            --config=*)
                ENV_FILE="${1#*=}"
                shift
                ;;
            -n|--non-interactive)
                NON_INTERACTIVE=1
                shift
                ;;
            --no-save-env)
                SAVE_ENV=0
                shift
                ;;
            --role-only)
                ROLE_ONLY=1
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                echo "Неизвестный аргумент: $1" >&2
                echo "Используйте --help для справки" >&2
                exit 1
                ;;
        esac
    done

    # Без управляющего терминала задавать вопросы невозможно
    # (cron, Ansible, CI). Переходим в неинтерактивный режим сами,
    # иначе первый же read упал бы с невнятной ошибкой.
    if (( NON_INTERACTIVE == 0 )) && ! [[ -r /dev/tty ]]; then
        NON_INTERACTIVE=1
    fi
}

# ─────────────────────────────────────────────────
# Проверка, что ключ входит в белый список
# ─────────────────────────────────────────────────
is_known_env_key() {
    local candidate="$1" key
    for key in "${ENV_KEYS[@]}"; do
        [[ "$key" == "$candidate" ]] && return 0
    done
    return 1
}

is_deprecated_env_key() {
    local candidate="$1" key
    for key in "${DEPRECATED_ENV_KEYS[@]}"; do
        [[ "$key" == "$candidate" ]] && return 0
    done
    return 1
}

# ─────────────────────────────────────────────────
# Загрузка параметров из файла конфигурации
#
# Файл разбирается построчно, а не через source: так он не может
# выполнить произвольный код, а неизвестные ключи отсеиваются по
# белому списку. Значения, уже заданные через окружение, не
# перезаписываются — окружение имеет более высокий приоритет.
# ─────────────────────────────────────────────────
load_env_file() {
    if [[ ! -f "$ENV_FILE" ]]; then
        if (( NON_INTERACTIVE == 1 )); then
            log_warning "Файл конфигурации не найден: $ENV_FILE"
        else
            log_info "Файл конфигурации не найден ($ENV_FILE) — параметры запросим интерактивно"
        fi
        return 0
    fi

    # Файл содержит ключи NetBird и SECRET_KEY — предупреждаем о правах
    local perms
    perms=$(stat -c '%a' "$ENV_FILE" 2>/dev/null || echo "?")
    if [[ "$perms" != "600" && "$perms" != "400" ]]; then
        log_warning "Права на $ENV_FILE = $perms, в файле секреты. Рекомендуется: chmod 600 $ENV_FILE"
    fi

    local line key value lineno=0 loaded=0 from_env=0
    while IFS= read -r line || [[ -n "$line" ]]; do
        lineno=$(( lineno + 1 ))
        line="${line%$'\r'}"   # файл мог быть создан в Windows (CRLF)

        # Пустые строки и комментарии
        [[ "$line" =~ ^[[:space:]]*$ ]] && continue
        [[ "$line" =~ ^[[:space:]]*# ]] && continue

        if [[ ! "$line" =~ ^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*=(.*)$ ]]; then
            log_warning "$ENV_FILE, строка $lineno: не распознана, пропущена"
            continue
        fi

        key="${BASH_REMATCH[2]}"
        value="${BASH_REMATCH[3]}"

        # Убираем окружающие пробелы (запись "KEY = value" тоже допустима),
        # затем окружающие кавычки
        value="${value#"${value%%[![:space:]]*}"}"
        value="${value%"${value##*[![:space:]]}"}"
        if [[ "$value" =~ ^\"(.*)\"$ ]] || [[ "$value" =~ ^\'(.*)\'$ ]]; then
            value="${BASH_REMATCH[1]}"
        fi

        if is_deprecated_env_key "$key"; then
            log_warning "$ENV_FILE, строка $lineno: параметр '$key' устарел (v3) и игнорируется — порты UFW теперь задаёт NODE_ROLE"
            continue
        fi

        if ! is_known_env_key "$key"; then
            log_warning "$ENV_FILE, строка $lineno: неизвестный параметр '$key', пропущен"
            continue
        fi

        # Окружение приоритетнее файла
        if [[ -n "${!key:-}" ]]; then
            from_env=$(( from_env + 1 ))
            continue
        fi

        printf -v "$key" '%s' "$value"
        loaded=$(( loaded + 1 ))
    done < "$ENV_FILE"

    log_info "Загружено параметров из $ENV_FILE: $loaded"
    if (( from_env > 0 )); then
        log_info "Переопределено через окружение: $from_env"
    fi
}

# ─────────────────────────────────────────────────
# Сохранение параметров в файл конфигурации
#
# Позволяет повторить установку на этой же ноде без вопросов.
# Файл содержит секреты, поэтому создаётся с правами 600.
# ─────────────────────────────────────────────────
save_env_file() {
    (( SAVE_ENV == 1 )) || return 0

    local env_dir
    env_dir=$(dirname "$ENV_FILE")

    if ! mkdir -p "$env_dir" 2>/dev/null; then
        log_warning "Не удалось создать $env_dir — параметры не сохранены"
        return 0
    fi

    # Права выставляем до записи, чтобы секреты не полежали
    # даже мгновение с правами по умолчанию
    local tmp_env="${ENV_FILE}.tmp"
    : > "$tmp_env"
    chmod 600 "$tmp_env"

    {
        echo "# Конфигурация Remnawave Node Auto-Installer"
        echo "# Создано автоматически: $(date +'%Y-%m-%d %H:%M:%S')"
        echo "#"
        echo "# Файл содержит секреты — держите права 600."
        echo "# Повторная установка с этими параметрами:"
        echo "#   sudo bash setup_remnawave_node.sh --config $ENV_FILE --non-interactive"
        echo ""
        local key
        for key in "${ENV_KEYS[@]}"; do
            printf '%s="%s"\n' "$key" "${!key:-}"
        done
    } >> "$tmp_env"

    mv "$tmp_env" "$ENV_FILE"
    chmod 600 "$ENV_FILE"

    log "✓ Параметры сохранены: $ENV_FILE (chmod 600)"
    log_info "Повторный запуск без вопросов: --config $ENV_FILE --non-interactive"
}

# ─────────────────────────────────────────────────
# Проверка прав root
# ─────────────────────────────────────────────────
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "Скрипт должен запускаться с правами root или через sudo"
        exit 1
    fi
}

# ─────────────────────────────────────────────────
# Автоопределение архитектуры процессора
# Поддерживается: x86_64 (amd64) и aarch64 (arm64)
# Это нужно для выбора правильного бинарника с GitHub Releases
# ─────────────────────────────────────────────────
detect_arch() {
    local raw_arch
    raw_arch=$(uname -m)

    case "$raw_arch" in
        x86_64)
            ARCH_SUFFIX="amd64"
            ;;
        aarch64 | arm64)
            ARCH_SUFFIX="arm64"
            ;;
        *)
            log_error "Неподдерживаемая архитектура: $raw_arch"
            log_error "Скрипт поддерживает только x86_64 и aarch64"
            exit 1
            ;;
    esac

    log_info "Обнаружена архитектура: $raw_arch → используем пакеты для $ARCH_SUFFIX"
}

# ─────────────────────────────────────────────────
# Проверка внешних зависимостей
#
# На минимальных образах Ubuntu/Debian wget отсутствует, тогда как
# curl обычно есть. Скрипт использует оба: curl — для установщиков
# NetBird и Docker, wget — для бинарников мониторинга. Раньше
# отсутствие wget обнаруживалось только в момент загрузки: три
# параллельных процесса падали с "command not found", а сообщение
# об ошибке говорило про недоступность GitHub.
#
# Теперь загрузчик выбирается по факту наличия, а недостающие
# пакеты доустанавливаются заранее — до долгих шагов установки.
# ─────────────────────────────────────────────────
ensure_dependencies() {
    log "Проверка зависимостей..."

    # Загрузчик: curl предпочтительнее — он нужен и для установщиков
    # NetBird и Docker, которые читают скрипт из pipe
    if command -v curl &> /dev/null; then
        DOWNLOADER="curl"
    elif command -v wget &> /dev/null; then
        DOWNLOADER="wget"
    fi

    # Собираем всё недостающее и ставим одной командой
    local missing_pkgs=()
    [[ -z "$DOWNLOADER" ]] && missing_pkgs+=("curl")
    command -v tar &> /dev/null || missing_pkgs+=("tar")
    # openssl — проверка сертификата и итоговая проверка сайта
    command -v openssl &> /dev/null || missing_pkgs+=("openssl")

    if (( ${#missing_pkgs[@]} > 0 )); then
        log_warning "Отсутствуют: ${missing_pkgs[*]} — устанавливаем"
        wait_for_apt_lock

        if apt install -y "${missing_pkgs[@]}" >> "$LOG_FILE" 2>&1; then
            log_info "✓ Установлено: ${missing_pkgs[*]}"
        else
            log_error "Не удалось установить: ${missing_pkgs[*]}"
            log_error "Установите вручную: apt install -y ${missing_pkgs[*]}"
            exit 1
        fi

        [[ -z "$DOWNLOADER" ]] && DOWNLOADER="curl"
    fi

    # Убеждаемся, что загрузчик действительно работает
    if ! command -v "$DOWNLOADER" &> /dev/null; then
        log_error "Загрузчик $DOWNLOADER недоступен после установки"
        exit 1
    fi

    log_info "✓ Загрузчик: $DOWNLOADER"
}

# ─────────────────────────────────────────────────
# Загрузка файла по URL в указанный путь
#
# Диагностика загрузчика намеренно НЕ подавляется: раньше
# wget вызывался с -q, поэтому причина сбоя (DNS, 404, таймаут,
# отсутствие самого wget) в лог не попадала, и сообщение об
# ошибке вводило в заблуждение.
#
# Аргументы: URL, путь назначения. Код возврата — от загрузчика.
# ─────────────────────────────────────────────────
download_file() {
    local url="$1"
    local dest="$2"

    case "$DOWNLOADER" in
        curl)
            # -f  — ненулевой код на HTTP-ошибках, иначе тело 404 сохранится как файл
            # -L  — идти за редиректами: GitHub перенаправляет релизы на CDN
            # -sS — без прогресс-бара, но с сообщениями об ошибках
            curl -fsSL --connect-timeout 30 --max-time 600 --retry 3 \
                 -o "$dest" "$url"
            ;;
        wget)
            wget --timeout=120 --tries=3 -O "$dest" "$url"
            ;;
        *)
            echo "внутренняя ошибка: загрузчик не определён" >&2
            return 1
            ;;
    esac
}

# ─────────────────────────────────────────────────
# Загрузка по URL в stdout (для установщиков вида "... | sh")
# ─────────────────────────────────────────────────
download_stdout() {
    local url="$1"

    case "$DOWNLOADER" in
        curl)
            curl -fsSL --connect-timeout 30 --max-time 600 "$url"
            ;;
        wget)
            wget -qO- --timeout=120 --tries=3 "$url"
            ;;
        *)
            echo "внутренняя ошибка: загрузчик не определён" >&2
            return 1
            ;;
    esac
}

# ─────────────────────────────────────────────────
# Валидация IPv4-адреса
# Используется при вводе IP панели
# ─────────────────────────────────────────────────
validate_ip() {
    local ip="$1"
    if [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        # Дополнительно проверяем, что каждый октет ≤ 255
        local IFS='.'
        read -ra octets <<< "$ip"
        for octet in "${octets[@]}"; do
            if (( octet > 255 )); then
                return 1
            fi
        done
        return 0
    fi
    return 1
}

# ─────────────────────────────────────────────────
# Валидация номера порта (1–65535)
# ─────────────────────────────────────────────────
validate_port() {
    local port="$1"
    if [[ "$port" =~ ^[0-9]+$ ]] && (( port >= 1 && port <= 65535 )); then
        return 0
    fi
    return 1
}

# ─────────────────────────────────────────────────
# Определение портов, на которых слушает SSH
#
# UFW с политикой "deny incoming" отрежет доступ к серверу,
# если разрешить только профиль OpenSSH (порт 22), а sshd
# слушает на нестандартном порту. Собираем порты из трёх
# независимых источников и объединяем: лучше открыть лишний
# порт, чем потерять управление сервером.
#
# Выводит найденные порты по одному на строку, отсортированные.
# ─────────────────────────────────────────────────
detect_ssh_ports() {
    local -A found=()   # ассоциативный массив используется как множество
    local port

    # Источник 1: директивы Port в конфигах sshd.
    # Директив может быть несколько (sshd слушает на всех перечисленных).
    local cfg
    for cfg in /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf; do
        [[ -f "$cfg" ]] || continue
        while read -r port; do
            validate_port "$port" && found["$port"]=1
        done < <(grep -ihsoP '^\s*Port\s+\K[0-9]+' "$cfg" 2>/dev/null || true)
    done

    # Источник 2: порт текущей SSH-сессии — самый достоверный признак,
    # если скрипт запущен по SSH. Формат SSH_CONNECTION:
    #   "<client_ip> <client_port> <server_ip> <server_port>"
    if [[ -n "${SSH_CONNECTION:-}" ]]; then
        port=$(awk '{print $4}' <<< "$SSH_CONNECTION")
        validate_port "$port" && found["$port"]=1
    fi

    # Источник 3: фактически прослушиваемые sshd сокеты
    if command -v ss &> /dev/null; then
        while read -r port; do
            validate_port "$port" && found["$port"]=1
        done < <(ss -tlnp 2>/dev/null | grep -F 'sshd' | grep -oP ':\K[0-9]+(?=\s)' || true)
    fi

    # Fallback: ничего не нашли — считаем что порт стандартный
    (( ${#found[@]} == 0 )) && found[22]=1

    printf '%s\n' "${!found[@]}" | sort -n
}

# ─────────────────────────────────────────────────
# Приведение адреса Victoria Metrics к полному URL
#
# Принимаем и голый IP, и URL со схемой, с портом или без.
# Используется и для интерактивного ввода, и для значения из .env,
# чтобы формат конечного URL не зависел от источника.
# ─────────────────────────────────────────────────
normalize_vm_url() {
    local input="$1"

    if [[ "$input" =~ ^https?:// ]]; then
        # Схема есть — добавляем порт, если его не указали
        if [[ "$input" =~ :[0-9]+(/|$) ]]; then
            echo "$input"
        else
            echo "${input}:8428"
        fi
    else
        # Голый IP или hostname — достраиваем схему и порт
        echo "http://${input}:8428"
    fi
}

# ─────────────────────────────────────────────────
# Проверка NetBird-адреса панели
# Возвращает 0 если адрес корректен, 1 если нет.
# Адрес вне пула 100.64.0.0/10 не считается ошибкой (пул
# переопределяем), но о нём предупреждаем.
# ─────────────────────────────────────────────────
check_panel_ip() {
    local ip="$1"

    validate_ip "$ip" || return 1

    # 100.64.0.0/10 — второй октет в диапазоне 64–127
    if [[ ! "$ip" =~ ^100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\. ]]; then
        log_warning "Адрес $ip вне стандартного пула NetBird (100.64.0.0/10)"
        log_warning "Убедитесь, что это адрес панели в mesh-сети, а не публичный IP"
    fi
    return 0
}

# ─────────────────────────────────────────────────
# Проверки ролей
# ─────────────────────────────────────────────────
validate_role() {
    [[ "$1" == "entry" || "$1" == "exit" || "$1" == "exit-direct" ]]
}

# Роли с nginx, сайтом-заглушкой и сертификатом
role_has_site() {
    [[ "$NODE_ROLE" == "entry" || "$NODE_ROLE" == "exit-direct" ]]
}

# Домен в нижнем регистре: метки из букв, цифр и дефисов.
# Строгая проверка нужна ещё и потому, что значение подставляется
# в шаблон nginx через sed.
validate_domain() {
    [[ "$1" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$ ]]
}

# ─────────────────────────────────────────────────
# Обязательный текстовый параметр роли
#
# Аргументы: имя переменной, имя массива недостающих, подсказка,
# необязательный флаг "secret" — тогда ввод не отображается.
# ─────────────────────────────────────────────────
require_param() {
    local var="$1" hint="$3" secret="${4:-}"
    local -n missing_list="$2"
    local input=""

    [[ -n "${!var:-}" ]] && return 0

    if (( NON_INTERACTIVE == 1 )); then
        missing_list+=("$var — $hint")
        return 0
    fi

    while [[ -z "$input" ]]; do
        if [[ "$secret" == "secret" ]]; then
            read -rsp "$(echo -e "${YELLOW}${var}${NC} (${hint}, ввод скрыт): ")" input < /dev/tty
            echo ""
        else
            read -rp "$(echo -e "${YELLOW}${var}${NC} (${hint}): ")" input < /dev/tty
        fi
        [[ -z "$input" ]] && echo -e "${RED}Поле обязательно для заполнения${NC}"
    done
    printf -v "$var" '%s' "$input"
}

# ─────────────────────────────────────────────────
# Локальный порт с значением по умолчанию (без вопроса)
# Аргументы: имя переменной, значение по умолчанию
# ─────────────────────────────────────────────────
resolve_local_port() {
    local var="$1" default="$2"

    printf -v "$var" '%s' "${!var:-$default}"
    if ! validate_port "${!var}"; then
        log_error "Некорректное значение $var='${!var}' (ожидается 1–65535)"
        exit 1
    fi
    if [[ "${!var}" == "443" || "${!var}" == "80" ]]; then
        log_error "$var=${!var}: порты 443 и 80 заняты публичными слушателями роли"
        exit 1
    fi
}

# ─────────────────────────────────────────────────
# Параметры ролей entry и exit-direct: домен, сертификат,
# локальные порты. Аргумент — имя массива недостающих параметров.
# ─────────────────────────────────────────────────
resolve_role_params() {
    local missing_name="$1"
    local -n missing_role="$1"

    # ─── NODE_DOMAIN ───
    NODE_DOMAIN="${NODE_DOMAIN,,}"
    if [[ -n "$NODE_DOMAIN" ]] && ! validate_domain "$NODE_DOMAIN"; then
        if (( NON_INTERACTIVE == 1 )); then
            log_error "Некорректный NODE_DOMAIN='$NODE_DOMAIN' (ожидается домен, например ru03.example.org)"
            exit 1
        fi
        log_warning "Некорректный NODE_DOMAIN='$NODE_DOMAIN' — запросим заново"
        NODE_DOMAIN=""
    fi
    if [[ -z "$NODE_DOMAIN" ]]; then
        if (( NON_INTERACTIVE == 1 )); then
            missing_role+=("NODE_DOMAIN — домен ноды, например ru03.example.org (роль $NODE_ROLE)")
        else
            while [[ -z "$NODE_DOMAIN" ]]; do
                read -rp "$(echo -e "${YELLOW}NODE_DOMAIN${NC} (домен ноды, например ru03.example.org): ")" NODE_DOMAIN < /dev/tty
                NODE_DOMAIN="${NODE_DOMAIN,,}"
                if ! validate_domain "$NODE_DOMAIN"; then
                    echo -e "${RED}Некорректный домен${NC}"
                    NODE_DOMAIN=""
                fi
            done
        fi
    fi

    # ─── Локальные порты ───
    resolve_local_port SITE_LOCAL_PORT "$DEFAULT_SITE_LOCAL_PORT"
    if [[ "$NODE_ROLE" == "entry" ]]; then
        resolve_local_port XRAY_LOCAL_PORT "$DEFAULT_XRAY_LOCAL_PORT"
        if [[ "$XRAY_LOCAL_PORT" == "$SITE_LOCAL_PORT" ]]; then
            log_error "XRAY_LOCAL_PORT и SITE_LOCAL_PORT совпадают ($SITE_LOCAL_PORT)"
            exit 1
        fi
    fi

    # ─── CERT_SOURCE ───
    if [[ -n "$CERT_SOURCE" && "$CERT_SOURCE" != "certwarden" && "$CERT_SOURCE" != "manual" ]]; then
        if (( NON_INTERACTIVE == 1 )); then
            log_error "Некорректный CERT_SOURCE='$CERT_SOURCE' (ожидается certwarden или manual)"
            exit 1
        fi
        log_warning "Некорректный CERT_SOURCE='$CERT_SOURCE' — запросим заново"
        CERT_SOURCE=""
    fi
    if [[ -z "$CERT_SOURCE" ]]; then
        if (( NON_INTERACTIVE == 1 )); then
            missing_role+=("CERT_SOURCE — certwarden или manual (роль $NODE_ROLE)")
            return 0
        fi
        echo -e "${CYAN}Источник сертификата:${NC}"
        echo -e "  ${GREEN}certwarden${NC} — CertWarden-клиент сам получает и продлевает сертификат"
        echo -e "  ${GREEN}manual${NC}     — вы кладёте ${CERT_FULLCHAIN} и ${CERT_PRIVKEY} в ${CERTS_DIR}"
        while [[ "$CERT_SOURCE" != "certwarden" && "$CERT_SOURCE" != "manual" ]]; do
            read -rp "$(echo -e "${YELLOW}CERT_SOURCE${NC} [certwarden/manual]: ")" CERT_SOURCE < /dev/tty
        done
    fi

    [[ "$CERT_SOURCE" == "certwarden" ]] || return 0

    # ─── Параметры CertWarden-клиента ───
    require_param CW_CLIENT_SERVER_ADDRESS "$missing_name" "адрес сервера CertWarden, https://..."
    require_param CW_CLIENT_CERT_NAME      "$missing_name" "имя сертификата в CertWarden"
    require_param CW_CLIENT_CERT_APIKEY    "$missing_name" "API-ключ сертификата" secret
    require_param CW_CLIENT_KEY_NAME       "$missing_name" "имя приватного ключа в CertWarden"
    require_param CW_CLIENT_KEY_APIKEY     "$missing_name" "API-ключ приватного ключа" secret
    require_param CW_CLIENT_AES_KEY_BASE64 "$missing_name" "AES-ключ из Post Processing сертификата" secret

    if [[ -n "$CW_CLIENT_SERVER_ADDRESS" && ! "$CW_CLIENT_SERVER_ADDRESS" =~ ^https:// ]]; then
        log_error "CW_CLIENT_SERVER_ADDRESS должен начинаться с https:// (сейчас: '$CW_CLIENT_SERVER_ADDRESS')"
        exit 1
    fi

    CW_CLIENT_FILE_UPDATE_TIME_START="${CW_CLIENT_FILE_UPDATE_TIME_START:-$DEFAULT_CW_TIME_START}"
    CW_CLIENT_FILE_UPDATE_TIME_END="${CW_CLIENT_FILE_UPDATE_TIME_END:-$DEFAULT_CW_TIME_END}"
    CW_CLIENT_FILE_UPDATE_DAYS_OF_WEEK="${CW_CLIENT_FILE_UPDATE_DAYS_OF_WEEK:-$DEFAULT_CW_DAYS}"
    TZ="${TZ:-$DEFAULT_TZ}"

    local t
    for t in "$CW_CLIENT_FILE_UPDATE_TIME_START" "$CW_CLIENT_FILE_UPDATE_TIME_END"; do
        if [[ ! "$t" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]; then
            log_error "Некорректное время окна обновления CertWarden: '$t' (ожидается ЧЧ:ММ)"
            exit 1
        fi
    done
}

# ─────────────────────────────────────────────────
# Определение итоговых значений параметров
#
# Для каждого параметра:
#   1. если значение уже есть (окружение или .env) — проверяем его;
#      некорректное в интерактивном режиме сбрасывается и
#      запрашивается заново, в неинтерактивном — это ошибка;
#   2. если значения нет — задаём вопрос либо, в неинтерактивном
#      режиме, добавляем параметр в список недостающих.
#
# Все недостающие параметры собираются и выводятся одним списком:
# при раскатке важно узнать обо всех пропусках сразу, а не
# по одному за запуск.
# ─────────────────────────────────────────────────
resolve_params() {
    local missing=()

    echo ""
    echo -e "${BLUE}╔════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║         Настройка параметров Remnawave Node v4.0.0                 ║${NC}"
    echo -e "${BLUE}╚════════════════════════════════════════════════════════════════════╝${NC}"
    echo ""

    if (( NON_INTERACTIVE == 1 )); then
        log_info "Неинтерактивный режим: вопросы задаваться не будут"
    fi
    if (( ROLE_ONLY == 1 )); then
        log_info "Режим --role-only: NetBird, Docker и мониторинг не трогаем, их параметры не нужны"
    fi

    # ─── Роль ноды ───
    # Спрашиваем первой: от неё зависит, какие параметры нужны дальше
    if [[ -n "$NODE_ROLE" ]] && ! validate_role "$NODE_ROLE"; then
        if (( NON_INTERACTIVE == 1 )); then
            log_error "Некорректное значение NODE_ROLE='$NODE_ROLE' (ожидается entry, exit или exit-direct)"
            exit 1
        fi
        log_warning "Некорректное значение NODE_ROLE='$NODE_ROLE' — запросим заново"
        NODE_ROLE=""
    fi
    if [[ -z "$NODE_ROLE" ]]; then
        if (( NON_INTERACTIVE == 1 )); then
            missing+=("NODE_ROLE — entry, exit или exit-direct")
        else
            echo -e "${CYAN}Роль ноды:${NC}"
            echo -e "  ${GREEN}entry${NC}        — входная (РФ): nginx на 443 разводит по SNI, сайт-заглушка"
            echo -e "  ${GREEN}exit${NC}         — выходная: трафик только по NetBird, наружу ничего не открыто"
            echo -e "  ${GREEN}exit-direct${NC}  — выходная с прямыми подключениями и Hysteria2"
            while [[ -z "$NODE_ROLE" ]]; do
                read -rp "$(echo -e "${YELLOW}NODE_ROLE${NC} [entry/exit/exit-direct]: ")" NODE_ROLE < /dev/tty
                if ! validate_role "$NODE_ROLE"; then
                    echo -e "${RED}Введите entry, exit или exit-direct${NC}"
                    NODE_ROLE=""
                fi
            done
        fi
    fi

    # ─── NetBird Setup Key ───
    if (( ROLE_ONLY == 0 )) && [[ -z "$NETBIRD_SETUP_KEY" ]]; then
        if (( NON_INTERACTIVE == 1 )); then
            missing+=("NETBIRD_SETUP_KEY — ключ из панели app.netbird.io")
        else
            while [[ -z "$NETBIRD_SETUP_KEY" ]]; do
                read -rp "$(echo -e "${YELLOW}NetBird Setup Key${NC} (из панели app.netbird.io): ")" NETBIRD_SETUP_KEY < /dev/tty
                [[ -z "$NETBIRD_SETUP_KEY" ]] && echo -e "${RED}Поле обязательно для заполнения${NC}"
            done
        fi
    fi

    # ─── Название инстанса ───
    if (( ROLE_ONLY == 0 )) && [[ -z "$INSTANCE_NAME" ]]; then
        if (( NON_INTERACTIVE == 1 )); then
            missing+=("INSTANCE_NAME — имя ноды для метрик, например de-node-01")
        else
            while [[ -z "$INSTANCE_NAME" ]]; do
                read -rp "$(echo -e "${YELLOW}Название инстанса${NC} (например: de-node-01, fi-node-01): ")" INSTANCE_NAME < /dev/tty
                [[ -z "$INSTANCE_NAME" ]] && echo -e "${RED}Поле обязательно для заполнения${NC}"
            done
        fi
    fi

    # ─── URL Victoria Metrics ───
    if [[ -n "$VICTORIA_METRICS_URL" ]]; then
        VICTORIA_METRICS_URL=$(normalize_vm_url "$VICTORIA_METRICS_URL")
    elif (( ROLE_ONLY == 1 )); then
        :   # мониторинг в этом режиме не настраивается
    elif (( NON_INTERACTIVE == 1 )); then
        missing+=("VICTORIA_METRICS_URL — IP или URL Victoria Metrics")
    else
        local vm_input=""
        while [[ -z "$VICTORIA_METRICS_URL" ]]; do
            read -rp "$(echo -e "${YELLOW}IP/URL Victoria Metrics${NC} (например: 10.0.0.1 или http://10.0.0.1:8428): ")" vm_input < /dev/tty
            if [[ -z "$vm_input" ]]; then
                echo -e "${RED}Поле обязательно для заполнения${NC}"
                continue
            fi
            VICTORIA_METRICS_URL=$(normalize_vm_url "$vm_input")
        done
    fi
    [[ -n "$VICTORIA_METRICS_URL" ]] && log_info "URL Victoria Metrics: $VICTORIA_METRICS_URL"

    # ─── NODE_PORT (необязательный, есть значение по умолчанию) ───
    if [[ -n "$NODE_PORT" ]] && ! validate_port "$NODE_PORT"; then
        if (( NON_INTERACTIVE == 1 )); then
            log_error "Некорректное значение NODE_PORT='$NODE_PORT' (ожидается 1–65535)"
            exit 1
        fi
        log_warning "Некорректное значение NODE_PORT='$NODE_PORT' — запросим заново"
        NODE_PORT=""
    fi
    if [[ -z "$NODE_PORT" ]]; then
        if (( NON_INTERACTIVE == 1 )); then
            NODE_PORT="$DEFAULT_NODE_PORT"
        else
            while true; do
                local node_port_input=""
                read -rp "$(echo -e "${YELLOW}NODE_PORT${NC} для связи с панелью [по умолчанию: ${DEFAULT_NODE_PORT}]: ")" node_port_input < /dev/tty
                node_port_input="${node_port_input:-$DEFAULT_NODE_PORT}"
                if validate_port "$node_port_input"; then
                    NODE_PORT="$node_port_input"
                    break
                fi
                echo -e "${RED}Некорректный порт. Введите число от 1 до 65535${NC}"
            done
        fi
    fi

    # ─── REMNANODE_VERSION ───
    # Без вопроса: значение по умолчанию подходит почти всегда, а
    # latest намеренно запрещён — ноды не должны разъезжаться по версиям
    REMNANODE_VERSION="${REMNANODE_VERSION:-$DEFAULT_REMNANODE_VERSION}"
    if [[ ! "$REMNANODE_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        log_error "Некорректный REMNANODE_VERSION='$REMNANODE_VERSION'"
        log_error "Нужен точный тег образа remnawave/node, например ${DEFAULT_REMNANODE_VERSION} (без 'v', не latest)"
        exit 1
    fi

    # ─── Параметры ролей с сайтом-заглушкой ───
    if [[ "$NODE_ROLE" == "entry" || "$NODE_ROLE" == "exit-direct" ]]; then
        resolve_role_params missing
    fi

    # ─── NetBird IP панели Remnawave ───
    #
    # Панель обращается к ноде через mesh-сеть, поэтому в правило UFW
    # нужен именно NetBird-адрес панели, а не её публичный IP:
    # с публичного адреса пакеты к ноде не придут.
    if [[ -n "$PANEL_NETBIRD_IP" ]] && ! check_panel_ip "$PANEL_NETBIRD_IP"; then
        if (( NON_INTERACTIVE == 1 )); then
            log_error "Некорректный PANEL_NETBIRD_IP='$PANEL_NETBIRD_IP' (ожидается IPv4, например 100.64.10.5)"
            exit 1
        fi
        log_warning "Некорректный PANEL_NETBIRD_IP='$PANEL_NETBIRD_IP' — запросим заново"
        PANEL_NETBIRD_IP=""
    fi
    if [[ -z "$PANEL_NETBIRD_IP" ]]; then
        if (( NON_INTERACTIVE == 1 )); then
            missing+=("PANEL_NETBIRD_IP — NetBird IP панели, обычно 100.x.x.x")
        else
            echo ""
            echo -e "${CYAN}NetBird IP панели${NC} — адрес панели ${YELLOW}внутри mesh-сети${NC} (обычно 100.x.x.x),"
            echo -e "а не её публичный IP. Найти: панель NetBird → Peers → строка сервера панели."
            while [[ -z "$PANEL_NETBIRD_IP" ]]; do
                read -rp "$(echo -e "${YELLOW}NetBird IP панели Remnawave${NC} (для правила UFW): ")" PANEL_NETBIRD_IP < /dev/tty
                if [[ -z "$PANEL_NETBIRD_IP" ]]; then
                    echo -e "${RED}Поле обязательно для заполнения${NC}"
                elif ! check_panel_ip "$PANEL_NETBIRD_IP"; then
                    echo -e "${RED}Некорректный IPv4-адрес. Пример: 100.64.10.5${NC}"
                    PANEL_NETBIRD_IP=""
                fi
            done
        fi
    fi

    # ─── SSH_PORTS: проверяем формат, если задан явно ───
    if [[ -n "$SSH_PORTS" ]]; then
        local p
        # shellcheck disable=SC2086
        for p in $SSH_PORTS; do
            if ! validate_port "$p"; then
                if (( NON_INTERACTIVE == 1 )); then
                    log_error "Некорректный порт в SSH_PORTS: '$p'"
                    exit 1
                fi
                log_warning "Некорректный порт в SSH_PORTS: '$p' — список будет определён автоматически"
                SSH_PORTS=""
                break
            fi
        done
    fi

    # ─── Отчёт о недостающих параметрах ───
    if (( ${#missing[@]} > 0 )); then
        echo ""
        log_error "Не заданы обязательные параметры:"
        local item
        for item in "${missing[@]}"; do
            log_error "   • $item"
        done
        echo ""
        log_error "Укажите их в файле конфигурации ($ENV_FILE) или через переменные окружения"
        log_error "Пример файла: см. .env.example в репозитории"
        log_error "Справка: $0 --help"
        exit 1
    fi

    echo ""
    echo -e "${CYAN}──────────────── Параметры установки ────────────────${NC}"
    log_info "Роль ноды:              $NODE_ROLE"
    if (( ROLE_ONLY == 0 )); then
        log_info "NetBird Setup Key:      [СКРЫТ]"
        log_info "Название инстанса:      $INSTANCE_NAME"
        log_info "Victoria Metrics URL:   $VICTORIA_METRICS_URL"
    fi
    log_info "NODE_PORT:              $NODE_PORT"
    log_info "remnawave/node:         $REMNANODE_VERSION"
    if role_has_site; then
        log_info "Домен ноды:             $NODE_DOMAIN"
        log_info "Сайт-заглушка:          127.0.0.1:$SITE_LOCAL_PORT"
        [[ "$NODE_ROLE" == "entry" ]] && log_info "Reality (Xray):         127.0.0.1:$XRAY_LOCAL_PORT"
        log_info "Сертификат:             $CERT_SOURCE"
        if [[ "$CERT_SOURCE" == "certwarden" ]]; then
            log_info "CertWarden-сервер:      $CW_CLIENT_SERVER_ADDRESS"
            log_info "Сертификат / ключ:      $CW_CLIENT_CERT_NAME / $CW_CLIENT_KEY_NAME (API-ключи скрыты)"
            log_info "Окно обновления файлов: $CW_CLIENT_FILE_UPDATE_TIME_START–$CW_CLIENT_FILE_UPDATE_TIME_END ($TZ), $CW_CLIENT_FILE_UPDATE_DAYS_OF_WEEK"
        fi
    fi
    log_info "NetBird IP панели:      $PANEL_NETBIRD_IP"
    log_info "SSH-порты:              ${SSH_PORTS:-определяются автоматически}"
    if [[ -n "$SECRET_KEY" ]]; then
        log_info "SECRET_KEY:             [ЗАДАН]"
    else
        log_info "SECRET_KEY:             не задан, будет плейсхолдер"
    fi
    echo ""
}

# ─────────────────────────────────────────────────
# Определение доступного метода проверки блокировок
#
# fuser входит в пакет psmisc, которого нет на minimal-образах
# Ubuntu/Debian и в контейнерах. Раньше его отсутствие давало
# ненулевой код возврата, что трактовалось как "лок свободен" —
# проверка молча вырождалась в заглушку. Теперь при отсутствии
# fuser используется скан /proc/*/fd: чистый bash, без внешних
# зависимостей.
#
# flock здесь не подходит: dpkg держит блокировку через
# fcntl(F_SETLK), а flock(2) на Linux с ней не конфликтует,
# поэтому такая проверка была бы ложноотрицательной.
# ─────────────────────────────────────────────────
detect_lock_check_method() {
    if command -v fuser &> /dev/null; then
        LOCK_CHECK_METHOD="fuser"
    else
        LOCK_CHECK_METHOD="proc"
        log_warning "fuser не найден (пакет psmisc отсутствует)"
        log_info "Проверяем APT-блокировку через скан /proc/*/fd"
    fi
}

# ─────────────────────────────────────────────────
# PID процессов, удерживающих открытым указанный файл
# Выводит PID по одному на строку (пусто — файл никем не открыт)
# ─────────────────────────────────────────────────
lock_holders() {
    local lock="$1"

    [[ -e "$lock" ]] || return 0   # файла нет — держать нечего

    if [[ "$LOCK_CHECK_METHOD" == "fuser" ]]; then
        # fuser выводит PID через пробелы в stdout, диагностику — в stderr
        fuser "$lock" 2>/dev/null | tr -s ' ' '\n' | grep -E '^[0-9]+$' || true
        return 0
    fi

    # Скан /proc: ищем процессы, у которых открыт дескриптор на этот файл.
    # Сравниваем цель символьной ссылки с путём лока — apt и dpkg
    # открывают его по каноническому абсолютному пути.
    local fd_path link pid
    for fd_path in /proc/[0-9]*/fd/*; do
        link=$(readlink "$fd_path" 2>/dev/null) || continue
        [[ "$link" == "$lock" ]] || continue
        pid=${fd_path#/proc/}
        pid=${pid%%/*}
        echo "$pid"
    done | sort -u
}

# ─────────────────────────────────────────────────
# Удерживается ли файл-блокировка кем-либо
# Возвращает 0 — удерживается, 1 — свободен
# ─────────────────────────────────────────────────
is_lock_held() {
    local holders
    holders=$(lock_holders "$1")
    [[ -n "$holders" ]]
}

# ─────────────────────────────────────────────────
# Ожидание освобождения блокировки APT/dpkg
#
# Ubuntu при старте автоматически запускает unattended-upgrades
# и apt-daily — фоновые службы обновления безопасности. На свежих
# серверах они могут держать блокировку 5–15 минут. Простое
# пассивное ожидание ненадёжно: мы не знаем заранее, сколько
# ждать. Поэтому функция сначала корректно останавливает эти
# службы через systemd, а уже потом ждёт освобождения лока
# (на случай если dpkg сам по себе ещё доделывает транзакцию).
#
# Важно: мы используем `systemctl stop`, а не `kill -9`. Принудительное
# убийство dpkg в середине транзакции может сломать базу пакетов.
# ─────────────────────────────────────────────────
wait_for_apt_lock() {
    local max_wait=60    # после остановки служб ждём не более 60с
    local waited=0
    local sleep_interval=3

    # Выбираем метод проверки локов при первом вызове
    [[ -n "$LOCK_CHECK_METHOD" ]] || detect_lock_check_method

    # Службы, которые чаще всего держат APT-блокировку на Ubuntu
    local blocking_services=(
        "unattended-upgrades"
        "apt-daily.service"
        "apt-daily-upgrade.service"
    )

    # Шаг 1: останавливаем фоновые apt-службы через systemd.
    # Это безопасно — systemd дождётся корректного завершения
    # текущей операции внутри службы перед тем как её остановить.
    local stopped_any=0
    for svc in "${blocking_services[@]}"; do
        set +e
        systemctl is-active --quiet "$svc" 2>/dev/null
        local is_active=$?
        set -e

        if (( is_active == 0 )); then
            log_warning "Останавливаем $svc (он держит APT-блокировку)..."
            # --no-block не нужен: мы хотим именно дождаться остановки
            systemctl stop "$svc" >> "$LOG_FILE" 2>&1 || true
            log_info "✓ $svc остановлен"
            stopped_any=1
        fi
    done

    if (( stopped_any == 1 )); then
        log_info "Фоновые APT-службы остановлены. Ждём освобождения блокировки dpkg..."
    fi

    # Шаг 2: восстановление dpkg после возможного прерывания.
    #
    # Если предыдущий запуск apt/dpkg был прерван (kill, reboot,
    # таймаут скрипта пока dpkg был в транзакции), база пакетов
    # остаётся в состоянии "interrupted". Любой следующий вызов apt
    # откажется работать с ошибкой "dpkg was interrupted, you must
    # manually run dpkg --configure -a". Мы делаем это автоматически:
    # если dpkg здоров — команда завершается мгновенно без изменений,
    # если повреждён — тихо восстанавливает финальное состояние пакетов.
    set +e
    dpkg --configure -a >> "$LOG_FILE" 2>&1
    local dpkg_rc=$?
    set -e
    if (( dpkg_rc == 0 )); then
        log_info "✓ dpkg в корректном состоянии"
    else
        log_warning "dpkg --configure -a завершился с кодом $dpkg_rc, продолжаем..."
    fi

    # Шаг 3: ждём пока dpkg сам отпустит файловый лок.
    # После остановки служб это обычно занимает секунды, но
    # может быть дольше если dpkg завершает транзакцию.
    local locks=("/var/lib/dpkg/lock-frontend" "/var/lib/apt/lists/lock")

    for lock in "${locks[@]}"; do
        while is_lock_held "$lock"; do
            if (( waited >= max_wait )); then
                local holders
                holders=$(lock_holders "$lock" | tr '\n' ' ')
                log_error "Таймаут ${max_wait}с: блокировка $lock не освободилась"
                log_error "Удерживающие процессы (PID): ${holders:-не определены}"
                log_error "Попробуйте вручную: systemctl stop unattended-upgrades && sudo bash setup_remnawave_node.sh"
                exit 1
            fi

            sleep "$sleep_interval"
            waited=$(( waited + sleep_interval ))
        done
    done

    if (( waited > 0 )); then
        log_info "✓ APT-блокировка освободилась (ждали ${waited}с)"
    fi
}

# ─────────────────────────────────────────────────
# Шаг 1: Обновление системы
# ─────────────────────────────────────────────────
update_system() {
    log "Шаг 1/4: Обновление системных пакетов..."

    export DEBIAN_FRONTEND=noninteractive

    # Ждём освобождения APT перед любым обращением к пакетному менеджеру
    wait_for_apt_lock

    if ! apt update >> "$LOG_FILE" 2>&1; then
        log_error "Ошибка при обновлении списков пакетов"
        exit 1
    fi
    log_info "✓ Списки пакетов обновлены"

    # Считаем количество доступных обновлений.
    # Используем set +e локально, т.к. grep возвращает код 1 при 0 совпадениях,
    # что при set -e прервало бы скрипт.
    set +e
    local upgradable
    upgradable=$(apt list --upgradable 2>/dev/null | grep -c "/" )
    set -e
    upgradable="${upgradable:-0}"

    if (( upgradable > 0 )); then
        log_warning "Найдено пакетов для обновления: $upgradable"
        log_warning "Это может занять несколько минут..."

        if apt upgrade -y \
            -o Dpkg::Options::="--force-confdef" \
            -o Dpkg::Options::="--force-confold" \
            >> "$LOG_FILE" 2>&1; then
            log "✓ Система успешно обновлена"
        else
            log_warning "apt upgrade завершился с предупреждениями, продолжаем..."
        fi
    else
        log "✓ Система уже актуальна (нет доступных обновлений)"
    fi

    unset DEBIAN_FRONTEND
}

# ─────────────────────────────────────────────────
# Шаг 2: Установка NetBird
# ─────────────────────────────────────────────────
install_netbird() {
    log "Шаг 2/4: Установка NetBird..."

    if command -v netbird &> /dev/null; then
        local ver
        ver=$(netbird version 2>/dev/null | head -n1 || echo "unknown")
        log_warning "NetBird уже установлен ($ver), пропускаем"
    else
        if download_stdout https://pkgs.netbird.io/install.sh | sh >> "$LOG_FILE" 2>&1; then
            log "✓ NetBird успешно установлен"
        else
            log_error "Ошибка при установке NetBird"
            exit 1
        fi
    fi
}

# ─────────────────────────────────────────────────
# Шаг 3: Подключение к NetBird
# ─────────────────────────────────────────────────
setup_netbird() {
    log "Шаг 3/4: Подключение к NetBird mesh-сети..."

    # netbird status возвращает ненулевой код если не подключён —
    # используем set +e для безопасной проверки
    set +e
    netbird status 2>/dev/null | grep -q "Connected"
    local already_connected=$?
    set -e

    if (( already_connected == 0 )); then
        log_warning "NetBird уже подключён к сети"
        netbird status | tee -a "$LOG_FILE"
    else
        if netbird up --setup-key "$NETBIRD_SETUP_KEY" >> "$LOG_FILE" 2>&1; then
            log "✓ NetBird успешно подключён"
            netbird status | tee -a "$LOG_FILE"
        else
            log_error "Ошибка при подключении NetBird"
            exit 1
        fi
    fi
}

# ─────────────────────────────────────────────────
# Шаг 4: Установка Docker
# ─────────────────────────────────────────────────
install_docker() {
    log "Шаг 4/4: Установка Docker..."

    # Docker-инсталлятор (get.docker.com) тоже вызывает apt внутри — ждём лок
    wait_for_apt_lock

    if command -v docker &> /dev/null; then
        local ver
        ver=$(docker --version)
        log_warning "Docker уже установлен ($ver), пропускаем"
    else
        if download_stdout https://get.docker.com | sh >> "$LOG_FILE" 2>&1; then
            log "✓ Docker успешно установлен"

            # Добавляем SUDO_USER в группу docker (если запущено через sudo)
            if [[ -n "${SUDO_USER:-}" ]]; then
                usermod -aG docker "$SUDO_USER"
                log_info "Пользователь $SUDO_USER добавлен в группу docker"
                log_warning "Для применения прав docker нужно перелогиниться"
            fi
        else
            log_error "Ошибка при установке Docker"
            exit 1
        fi
    fi
}

# ─────────────────────────────────────────────────
# Создание директории проекта remnawave
# ─────────────────────────────────────────────────
create_project_dir() {
    if [[ ! -d "$PROJECT_DIR" ]]; then
        mkdir -p "$PROJECT_DIR"
        log "✓ Создана директория проекта: $PROJECT_DIR"
    else
        log_warning "Директория $PROJECT_DIR уже существует"
    fi
}

# ─────────────────────────────────────────────────
# Создание директорий для мониторинга
# ─────────────────────────────────────────────────
create_monitoring_dirs() {
    mkdir -p "$MONITORING_DIR"/{cadvisor,nodeexporter,vmagent/conf.d}
    log "✓ Созданы директории для мониторинга"
}

# ─────────────────────────────────────────────────
# Определение версии установленного бинарника
#
# Компоненты используют разные библиотеки разбора флагов:
# node_exporter собран на kingpin и понимает только --version,
# cAdvisor и vmagent используют стандартный Go flag, который
# принимает обе формы. Поэтому пробуем оба варианта по очереди
# и берём первый вывод, из которого удалось извлечь версию.
#
# Возвращает:
#   "none"    — файла нет или он не исполняемый
#   "unknown" — бинарник есть, но версию извлечь не удалось
#   x.y.z     — найденная версия
# ─────────────────────────────────────────────────
get_binary_version() {
    local binary="$1"

    if [[ ! -x "$binary" ]]; then
        echo "none"
        return
    fi

    local flag out ver
    for flag in --version -version; do
        set +e
        out=$("$binary" "$flag" 2>&1)
        set -e

        ver=$(grep -oP '\d+\.\d+\.\d+' <<< "$out" | head -n1 || true)
        if [[ -n "$ver" ]]; then
            echo "$ver"
            return
        fi
    done

    echo "unknown"
}

# ─────────────────────────────────────────────────
# Установка cAdvisor
# Выполняется в фоне (параллельно с другими загрузками)
# Статус записывается в $TMP_DIR/cadvisor.status
# ─────────────────────────────────────────────────
install_cadvisor() {
    local target="$MONITORING_DIR/cadvisor/cadvisor"
    local status_file="$TMP_DIR/cadvisor.status"
    local log_file="$TMP_DIR/cadvisor.log"

    {
        # Проверяем текущую версию (если бинарник уже есть)
        local current_ver
        current_ver=$(get_binary_version "$target")

        if [[ "$current_ver" == "$CADVISOR_VERSION" ]]; then
            echo "SKIP" > "$status_file"
            echo "cAdvisor v${CADVISOR_VERSION} уже установлен" >> "$log_file"
            return
        elif [[ "$current_ver" == "unknown" ]]; then
            echo "Версия существующего бинарника cAdvisor не определена — скачиваем заново" >> "$log_file"
        elif [[ "$current_ver" != "none" ]]; then
            echo "Обновление cAdvisor $current_ver → $CADVISOR_VERSION" >> "$log_file"
        fi

        local url="https://github.com/google/cadvisor/releases/download/v${CADVISOR_VERSION}/cadvisor-v${CADVISOR_VERSION}-linux-${ARCH_SUFFIX}"

        if download_file "$url" "${target}.tmp" >> "$log_file" 2>&1; then
            mv "${target}.tmp" "$target"
            chmod +x "$target"
            echo "OK" > "$status_file"
            echo "cAdvisor v${CADVISOR_VERSION} установлен" >> "$log_file"
        else
            rm -f "${target}.tmp"
            echo "FAIL" > "$status_file"
            echo "ошибка при скачивании cAdvisor ($url)" >> "$log_file"
        fi
    }
}

# ─────────────────────────────────────────────────
# Установка Node Exporter
# ─────────────────────────────────────────────────
install_node_exporter() {
    local target="$MONITORING_DIR/nodeexporter/node_exporter"
    local status_file="$TMP_DIR/nodeexporter.status"
    local log_file="$TMP_DIR/nodeexporter.log"

    {
        local current_ver
        current_ver=$(get_binary_version "$target")

        if [[ "$current_ver" == "$NODE_EXPORTER_VERSION" ]]; then
            echo "SKIP" > "$status_file"
            echo "Node Exporter v${NODE_EXPORTER_VERSION} уже установлен" >> "$log_file"
            return
        elif [[ "$current_ver" == "unknown" ]]; then
            echo "Версия существующего бинарника Node Exporter не определена — скачиваем заново" >> "$log_file"
        elif [[ "$current_ver" != "none" ]]; then
            echo "Обновление Node Exporter $current_ver → $NODE_EXPORTER_VERSION" >> "$log_file"
        fi

        local archive="node_exporter-${NODE_EXPORTER_VERSION}.linux-${ARCH_SUFFIX}.tar.gz"
        local url="https://github.com/prometheus/node_exporter/releases/download/v${NODE_EXPORTER_VERSION}/${archive}"
        local tmp_archive="${TMP_DIR}/${archive}"
        local unpacked="${TMP_DIR}/node_exporter-${NODE_EXPORTER_VERSION}.linux-${ARCH_SUFFIX}"

        if download_file "$url" "$tmp_archive" >> "$log_file" 2>&1 \
            && tar -xzf "$tmp_archive" -C "$TMP_DIR" >> "$log_file" 2>&1 \
            && mv "${unpacked}/node_exporter" "$target"; then
            chmod +x "$target"
            # Очищаем распакованную директорию
            rm -rf "$unpacked" "$tmp_archive"
            echo "OK" > "$status_file"
            echo "Node Exporter v${NODE_EXPORTER_VERSION} установлен" >> "$log_file"
        else
            rm -rf "$unpacked" "$tmp_archive"
            echo "FAIL" > "$status_file"
            echo "ошибка при загрузке или распаковке Node Exporter ($url)" >> "$log_file"
        fi
    }
}

# ─────────────────────────────────────────────────
# Установка VictoriaMetrics Agent
# ─────────────────────────────────────────────────
install_vmagent() {
    local target="$MONITORING_DIR/vmagent/vmagent"
    local status_file="$TMP_DIR/vmagent.status"
    local log_file="$TMP_DIR/vmagent.log"

    {
        local current_ver
        current_ver=$(get_binary_version "$target")

        if [[ "$current_ver" == "$VMAGENT_VERSION" ]]; then
            echo "SKIP" > "$status_file"
            echo "vmagent v${VMAGENT_VERSION} уже установлен" >> "$log_file"
            return
        elif [[ "$current_ver" == "unknown" ]]; then
            echo "Версия существующего бинарника vmagent не определена — скачиваем заново" >> "$log_file"
        elif [[ "$current_ver" != "none" ]]; then
            echo "Обновление vmagent $current_ver → $VMAGENT_VERSION" >> "$log_file"
        fi

        # Для arm64 VictoriaMetrics использует суффикс "arm64" в архиве
        local vm_arch="$ARCH_SUFFIX"
        local archive="vmutils-linux-${vm_arch}-v${VMAGENT_VERSION}.tar.gz"
        local url="https://github.com/VictoriaMetrics/VictoriaMetrics/releases/download/v${VMAGENT_VERSION}/${archive}"
        local tmp_archive="${TMP_DIR}/${archive}"

        if download_file "$url" "$tmp_archive" >> "$log_file" 2>&1 \
            && tar -xzf "$tmp_archive" -C "$TMP_DIR" >> "$log_file" 2>&1 \
            && mv "${TMP_DIR}/vmagent-prod" "$target"; then
            chmod +x "$target"
            rm -f "$tmp_archive"
            # Удаляем прочие бинарники из vmutils (vmbackup, vmctl и т.д.)
            find "$TMP_DIR" -maxdepth 1 -name "*-prod" -delete 2>/dev/null || true
            echo "OK" > "$status_file"
            echo "vmagent v${VMAGENT_VERSION} установлен" >> "$log_file"
        else
            rm -f "$tmp_archive"
            find "$TMP_DIR" -maxdepth 1 -name "*-prod" -delete 2>/dev/null || true
            echo "FAIL" > "$status_file"
            echo "ошибка при загрузке или распаковке vmagent ($url)" >> "$log_file"
        fi
    }
}

# ─────────────────────────────────────────────────
# Запуск параллельной загрузки всех трёх бинарников
#
# Вместо трёх последовательных загрузок (~60–120с каждая)
# запускаем все три одновременно в фоне.
# Суммарное время = время самой медленной загрузки.
# ─────────────────────────────────────────────────
install_all_monitoring_binaries() {
    log "Параллельная загрузка компонентов мониторинга (cAdvisor, Node Exporter, vmagent)..."
    log_info "Архитектура: linux-${ARCH_SUFFIX}"

    # Инициализируем файлы статусов значением "pending"
    echo "pending" > "$TMP_DIR/cadvisor.status"
    echo "pending" > "$TMP_DIR/nodeexporter.status"
    echo "pending" > "$TMP_DIR/vmagent.status"

    # Запускаем загрузки в фоновых подпроцессах
    install_cadvisor &
    local pid_cadvisor=$!

    install_node_exporter &
    local pid_nodeexporter=$!

    install_vmagent &
    local pid_vmagent=$!

    # Ждём завершения каждого процесса и проверяем результат
    local has_error=0

    wait "$pid_cadvisor"  || true
    wait "$pid_nodeexporter" || true
    wait "$pid_vmagent" || true

    # Читаем статусы из файлов (фоновые процессы могут завершиться с 0
    # даже при ошибке внутри функции, поэтому используем файл статуса).
    # Протокол: файл статуса содержит ровно одно слово — OK, SKIP или FAIL;
    # значение "pending" означает, что подпроцесс не дошёл до записи статуса.
    local components=("cadvisor" "nodeexporter" "vmagent")
    for comp in "${components[@]}"; do
        local status_file="$TMP_DIR/${comp}.status"
        local log_file="$TMP_DIR/${comp}.log"

        # Пишем лог компонента в основной лог
        if [[ -f "$log_file" ]]; then
            cat "$log_file" >> "$LOG_FILE"
        fi

        local status="MISSING"
        [[ -f "$status_file" ]] && status=$(cat "$status_file")

        # Итог компонента — последняя строка его лога
        local msg=""
        [[ -f "$log_file" ]] && msg=$(tail -n1 "$log_file" 2>/dev/null || true)

        case "$status" in
            OK)
                log_info "✓ $comp: ${msg:-установлен}"
                ;;
            SKIP)
                log_warning "$comp: ${msg:-уже актуальной версии, пропущен}"
                ;;
            FAIL)
                log_error "$comp: ${msg:-ошибка установки}"
                has_error=1
                ;;
            pending|MISSING)
                log_error "$comp: загрузка не завершилась (статус: $status)"
                has_error=1
                ;;
            *)
                log_error "$comp: неизвестный статус '$status'"
                has_error=1
                ;;
        esac
    done

    if (( has_error == 1 )); then
        log_error "Один или несколько компонентов не удалось установить"
        exit 1
    fi

    log "✓ Все бинарники мониторинга успешно установлены"
}

# ─────────────────────────────────────────────────
# Создание конфигурационных файлов мониторинга
#
# ВАЖНО: heredoc-блоки намеренно начинаются с колонки 0,
# без отступа перед содержимым. Это предотвращает попадание
# лишних пробелов в YAML (при отступленном heredoc bash
# вставил бы пробелы в начало каждой строки).
# ─────────────────────────────────────────────────
create_monitoring_configs() {
    log "Создание конфигурационных файлов мониторинга..."

    # Основной конфиг vmagent: указывает на директорию с job-файлами
cat > "$MONITORING_DIR/vmagent/scrape.yml" <<EOF
scrape_config_files:
  - "/opt/monitoring/vmagent/conf.d/*.yml"

global:
  scrape_interval: 15s
  external_labels:
    instance: "${INSTANCE_NAME}"
EOF
    log_info "✓ scrape.yml"

    # Job для cAdvisor
cat > "$MONITORING_DIR/vmagent/conf.d/cadvisor.yml" <<EOF
- job_name: integrations/cAdvisor
  scrape_interval: 15s
  static_configs:
    - targets: ['localhost:9101']
      labels:
        instance: "${INSTANCE_NAME}"
EOF
    log_info "✓ conf.d/cadvisor.yml"

    # Job для Node Exporter
cat > "$MONITORING_DIR/vmagent/conf.d/nodeexporter.yml" <<EOF
- job_name: integrations/node_exporter
  scrape_interval: 15s
  static_configs:
    - targets: ['localhost:9100']
      labels:
        instance: "${INSTANCE_NAME}"
EOF
    log_info "✓ conf.d/nodeexporter.yml"

    # systemd unit — cAdvisor
cat > /etc/systemd/system/cadvisor.service <<EOF
[Unit]
Description=cAdvisor - Container Advisor
Wants=network-online.target
After=network-online.target docker.service

[Service]
User=root
Group=root
Type=simple
ExecStart=/opt/monitoring/cadvisor/cadvisor \\
  -listen_ip=127.0.0.1 \\
  -port=9101 \\
  -logtostderr \\
  -docker_only=true
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
    log_info "✓ cadvisor.service"

    # systemd unit — Node Exporter
cat > /etc/systemd/system/nodeexporter.service <<EOF
[Unit]
Description=Prometheus Node Exporter
Wants=network-online.target
After=network-online.target

[Service]
User=root
Group=root
Type=simple
ExecStart=/opt/monitoring/nodeexporter/node_exporter \\
  --web.listen-address=127.0.0.1:9100
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
    log_info "✓ nodeexporter.service"

    # systemd unit — vmagent
cat > /etc/systemd/system/vmagent.service <<EOF
[Unit]
Description=VictoriaMetrics Agent
Wants=network-online.target
After=network-online.target

[Service]
User=root
Group=root
Type=simple
ExecStart=/opt/monitoring/vmagent/vmagent \\
  -httpListenAddr=127.0.0.1:8429 \\
  -promscrape.config=/opt/monitoring/vmagent/scrape.yml \\
  -promscrape.configCheckInterval=60s \\
  -remoteWrite.url=${VICTORIA_METRICS_URL}/api/v1/write
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
    log_info "✓ vmagent.service"

    log "✓ Все конфигурационные файлы созданы"
}

# ─────────────────────────────────────────────────
# Запуск и включение сервисов мониторинга
# ─────────────────────────────────────────────────
start_monitoring_services() {
    log "Запуск сервисов мониторинга..."

    systemctl daemon-reload >> "$LOG_FILE" 2>&1
    systemctl enable cadvisor nodeexporter vmagent >> "$LOG_FILE" 2>&1
    log_info "✓ Сервисы добавлены в автозагрузку"

    systemctl start cadvisor nodeexporter vmagent >> "$LOG_FILE" 2>&1
    log "✓ Сервисы запущены"

    # Краткая проверка — даём сервисам 3 секунды на старт
    sleep 3
    echo ""
    for svc in cadvisor nodeexporter vmagent; do
        if systemctl is-active --quiet "$svc"; then
            log_info "✓ $svc: активен"
        else
            log_warning "⚠ $svc: не активен, проверьте: journalctl -xeu $svc"
        fi
    done
}

# ─────────────────────────────────────────────────
# Подтверждение SSH-портов перед включением UFW
#
# Это единственный шаг, ошибка в котором стоит потери доступа
# к серверу, поэтому список портов показывается пользователю
# и требует явного подтверждения.
# ─────────────────────────────────────────────────
confirm_ssh_ports() {
    # Порты, заданные явно через SSH_PORTS, используются как есть:
    # пользователь уже сделал осознанный выбор, переспрашивать незачем.
    if [[ -n "$SSH_PORTS" ]]; then
        # shellcheck disable=SC2206
        SSH_PORT_LIST=($SSH_PORTS)
        log_info "SSH-порты заданы явно: ${SSH_PORT_LIST[*]}"
        return 0
    fi

    mapfile -t SSH_PORT_LIST < <(detect_ssh_ports)

    # В неинтерактивном режиме полагаемся на автоопределение.
    # Оно смотрит в sshd_config, в порт текущей сессии и в живые
    # сокеты, но подтвердить его некому — поэтому пишем в лог явно.
    if (( NON_INTERACTIVE == 1 )); then
        log_warning "Неинтерактивный режим: SSH-порты определены автоматически: ${SSH_PORT_LIST[*]}"
        log_warning "Если список неполон, доступ по SSH будет потерян после включения UFW"
        log_info "Задайте SSH_PORTS в конфигурации, чтобы не полагаться на автоопределение"
        return 0
    fi

    echo ""
    echo -e "${CYAN}──────────────── SSH и firewall ────────────────${NC}"
    echo -e "Обнаружены SSH-порты: ${GREEN}${SSH_PORT_LIST[*]}${NC}"
    echo -e "Они будут разрешены в UFW ${YELLOW}до${NC} его включения."
    echo -e "${RED}Если список неполный — вы потеряете доступ к серверу по SSH.${NC}"
    echo ""

    local answer
    while true; do
        read -rp "$(echo -e "Продолжить с этими портами? [${GREEN}Y${NC}=да / ${RED}n${NC}=отмена / ${YELLOW}e${NC}=изменить]: ")" answer < /dev/tty
        answer="${answer:-y}"

        case "${answer,,}" in
            y|yes|д|да)
                return 0
                ;;
            e|edit|и|изменить)
                local custom_input
                local -a custom_ports=()
                read -rp "$(echo -e "${YELLOW}SSH-порты через пробел${NC}: ")" custom_input < /dev/tty

                local p
                local valid=1
                # $custom_input намеренно без кавычек: нужен разбор
                # строки на отдельные порты по пробелам
                # shellcheck disable=SC2086
                for p in $custom_input; do
                    if validate_port "$p"; then
                        custom_ports+=("$p")
                    else
                        echo -e "${RED}Некорректный порт: $p${NC}"
                        valid=0
                        break
                    fi
                done

                if (( valid == 1 )) && (( ${#custom_ports[@]} > 0 )); then
                    SSH_PORT_LIST=("${custom_ports[@]}")
                    SSH_PORTS="${custom_ports[*]}"   # чтобы попало в .env
                    echo -e "Порты обновлены: ${GREEN}${SSH_PORT_LIST[*]}${NC}"
                else
                    echo -e "${RED}Список не изменён, введите ещё раз${NC}"
                fi
                ;;
            n|no|н|нет)
                log_error "Установка прервана пользователем до включения UFW"
                log_info "Firewall не изменён, доступ к серверу сохранён"
                exit 1
                ;;
            *)
                echo -e "${RED}Введите y, n или e${NC}"
                ;;
        esac
    done
}

# ─────────────────────────────────────────────────
# Публичные порты роли — открыты в UFW для всех
# ─────────────────────────────────────────────────
UFW_ROLE_COMMENT="Remnawave role"

role_public_ports() {
    case "$NODE_ROLE" in
        entry)       echo "443/tcp 80/tcp" ;;
        exit)        echo "" ;;
        exit-direct) echo "443/tcp 443/udp 8443/tcp 80/tcp" ;;
    esac
}

# ─────────────────────────────────────────────────
# Удаление правил UFW, которыми управляет скрипт, но которых
# нет в наборе текущей роли
#
# Управляемыми считаются правила с комментарием UFW_ROLE_COMMENT
# и правила XRAY_PORT из v3 ("Xray TCP" / "Xray UDP"). Остальные
# правила — SSH, NODE_PORT, добавленные вручную — не трогаются.
# ─────────────────────────────────────────────────
prune_role_rules() {
    local wanted line num to guard=0
    wanted=" $(role_public_ports) "

    # После каждого удаления нумерация сдвигается, поэтому
    # перечитываем список заново
    while (( guard < 50 )); do
        guard=$(( guard + 1 ))
        num=""
        while IFS= read -r line; do
            [[ "$line" =~ \#\ (Xray\ TCP|Xray\ UDP|${UFW_ROLE_COMMENT})$ ]] || continue
            [[ "$line" =~ ^\[\ *([0-9]+)\]\ +([0-9]+/(tcp|udp)) ]] || continue
            to="${BASH_REMATCH[2]}"
            if [[ "$wanted" != *" $to "* ]]; then
                num="${BASH_REMATCH[1]}"
                break
            fi
        done < <(ufw status numbered 2>/dev/null)

        [[ -z "$num" ]] && break
        ufw --force delete "$num" >> "$LOG_FILE" 2>&1
        log_info "✓ Удалено правило UFW вне роли $NODE_ROLE: $to"
    done
}

# ─────────────────────────────────────────────────
# Настройка UFW Firewall
#
# Публичные порты задаёт роль (role_public_ports). NODE_PORT
# открываем только для NetBird-адреса панели: панель обращается
# к ноде через mesh-сеть, поэтому источником пакетов будет её
# адрес в NetBird, а не публичный IP.
# ─────────────────────────────────────────────────
configure_firewall() {
    log "Настройка UFW Firewall..."

    if ! command -v ufw &> /dev/null; then
        log_info "UFW не установлен, устанавливаем..."
        wait_for_apt_lock
        apt install -y ufw >> "$LOG_FILE" 2>&1
        log_info "✓ UFW установлен"
    fi

    # SSH — разрешаем в первую очередь, чтобы не потерять доступ.
    # Профиль OpenSSH не используем: он жёстко привязан к порту 22.
    confirm_ssh_ports

    local ssh_port
    for ssh_port in "${SSH_PORT_LIST[@]}"; do
        ufw allow "$ssh_port"/tcp comment "SSH" >> "$LOG_FILE" 2>&1
        log_info "✓ SSH $ssh_port/tcp: разрешён"
    done

    # NODE_PORT — только с NetBird-адреса панели
    ufw allow from "$PANEL_NETBIRD_IP" to any port "$NODE_PORT" proto tcp \
        comment "Remnawave panel (NetBird) -> node" >> "$LOG_FILE" 2>&1
    log_info "✓ NODE_PORT $NODE_PORT: разрешён только для $PANEL_NETBIRD_IP (NetBird)"

    # Публичные порты роли. Правила прошлых запусков, которых нет в
    # наборе текущей роли, удаляются — так --role-only приводит ноду
    # к стандарту. BRIDGE_PORT не открывается никогда: мост идёт
    # через NetBird, а его правила стоят раньше UFW
    local rule
    prune_role_rules
    for rule in $(role_public_ports); do
        ufw allow "$rule" comment "$UFW_ROLE_COMMENT" >> "$LOG_FILE" 2>&1
        log_info "✓ $rule: разрешён для всех (роль $NODE_ROLE)"
    done
    if [[ -z "$(role_public_ports)" ]]; then
        log_info "Роль $NODE_ROLE: публичных портов нет, трафик приходит по NetBird"
    fi

    # Включаем UFW (echo y — автоматически соглашаемся на предупреждение)
    echo "y" | ufw enable >> "$LOG_FILE" 2>&1

    if ufw status | grep -q "Status: active"; then
        log "✓ UFW активирован"
        echo ""
        ufw status numbered | tee -a "$LOG_FILE"
    else
        log_error "UFW не активировался"
        exit 1
    fi
}

# ─────────────────────────────────────────────────
# Получение NetBird IP
# ─────────────────────────────────────────────────
get_netbird_ip() {
    log_info "Определяем NetBird IP..."

    # Пробуем распарсить из netbird status
    set +e
    NETBIRD_IP=$(netbird status 2>/dev/null | grep -oP 'NetBird IP:\s+\K[0-9.]+')
    set -e

    # Если не получилось — смотрим на интерфейс wt0
    if [[ -z "$NETBIRD_IP" ]]; then
        set +e
        NETBIRD_IP=$(ip addr show wt0 2>/dev/null | grep -oP 'inet \K[0-9.]+')
        set -e
    fi

    NETBIRD_FQDN=$(netbird status 2>/dev/null | grep -oP '^FQDN:\s+\K\S+' || true)

    if [[ -n "$NETBIRD_IP" ]]; then
        log "✓ NetBird IP: ${GREEN}$NETBIRD_IP${NC}"
    else
        log_warning "Не удалось автоматически определить NetBird IP"
        log_info "Запустите вручную: netbird status"
    fi
}

# ═════════════════════════════════════════════════
# Ролевая часть: предпроверки, сертификаты, nginx,
# CertWarden-клиент, remnanode
# ═════════════════════════════════════════════════

# ─────────────────────────────────────────────────
# Для --role-only: базовая часть уже должна стоять
# ─────────────────────────────────────────────────
check_role_only_prereqs() {
    local missing=()
    command -v docker &> /dev/null || missing+=("docker")
    command -v netbird &> /dev/null || missing+=("netbird")
    command -v ufw &> /dev/null || missing+=("ufw")

    if (( ${#missing[@]} > 0 )); then
        log_error "Режим --role-only: не найдено: ${missing[*]}"
        log_error "Это не настроенный сервер — запустите полную установку без --role-only"
        exit 1
    fi
    if ! docker compose version &> /dev/null; then
        log_error "Не найден плагин docker compose (docker compose version)"
        exit 1
    fi
}

# ─────────────────────────────────────────────────
# PID процессов, слушающих TCP-порт на хосте
# ─────────────────────────────────────────────────
port_listener_pids() {
    ss -Htlnp "sport = :$1" 2>/dev/null | grep -oP 'pid=\K[0-9]+' | sort -u || true
}

# PID всех процессов контейнера (пусто — контейнера нет или он остановлен)
container_pids() {
    command -v docker &> /dev/null || return 0
    docker top "$1" -eo pid 2>/dev/null | tail -n +2 | tr -d ' ' || true
}

container_exists() {
    command -v docker &> /dev/null || return 1
    docker inspect "$1" &> /dev/null
}

container_running() {
    [[ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null)" == "true" ]]
}

# ─────────────────────────────────────────────────
# Свободен ли TCP-порт
#
# Порт считается свободным, если его никто не слушает или слушают
# только процессы перечисленных контейнеров — это повторный запуск
# скрипта на уже настроенной ноде. Чужой процесс скрипт не
# останавливает, а показывает, кто держит порт.
#
# Аргументы: порт, затем имена «своих» контейнеров.
# Возвращает 1, если порт занят чужим процессом.
# ─────────────────────────────────────────────────
check_port_free() {
    local port="$1"
    shift

    local -A own=()
    local c pid
    for c in "$@"; do
        while read -r pid; do
            [[ -n "$pid" ]] && own["$pid"]=1
        done < <(container_pids "$c")
    done

    local foreign=0
    while read -r pid; do
        [[ -z "$pid" ]] && continue
        [[ -n "${own[$pid]:-}" ]] || foreign=1
    done < <(port_listener_pids "$port")

    if (( foreign == 1 )); then
        log_error "Порт $port/tcp занят:"
        ss -tlnp "sport = :$port" 2>/dev/null | tee -a "$LOG_FILE"
        return 1
    fi
    return 0
}

# ─────────────────────────────────────────────────
# Контейнер с нашим именем создан из другого места
#
# docker compose не может управлять контейнером, созданным другим
# compose-проектом или вручную: up -d упадёт на конфликте имён.
# Аргументы: имя контейнера, ожидаемая директория compose-проекта.
# ─────────────────────────────────────────────────
check_container_owner() {
    local name="$1" dir="$2" workdir

    container_exists "$name" || return 0
    workdir=$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project.working_dir"}}' "$name" 2>/dev/null || true)

    if [[ "$workdir" != "$dir" ]]; then
        log_error "Контейнер '$name' уже существует, но создан не из $dir (${workdir:-не через docker compose})"
        log_error "Остановите и удалите его вручную: docker rm -f $name"
        return 1
    fi
    return 0
}

# ─────────────────────────────────────────────────
# Образы, нужные роли
# ─────────────────────────────────────────────────
role_images() {
    echo "remnawave/node:${REMNANODE_VERSION}"
    if role_has_site; then
        echo "$NGINX_IMAGE"
        [[ "$CERT_SOURCE" == "certwarden" ]] && echo "$CERTWARDEN_IMAGE"
    fi
    return 0
}

# ─────────────────────────────────────────────────
# Есть ли тег в реестре — через HTTP API, без Docker
#
# Нужно для полной установки: на этапе предпроверок Docker ещё не
# установлен. Поддерживаются Docker Hub и ghcr.io — других
# реестров скрипт не использует.
# Возвращает 0 — тег есть, 1 — тега нет, 2 — проверить не удалось.
# ─────────────────────────────────────────────────
registry_tag_exists() {
    local ref="$1" name tag registry repo auth_url api_host

    name="${ref%:*}"
    tag="${ref##*:}"
    if [[ "$name" == */* && "${name%%/*}" == *.* ]]; then
        registry="${name%%/*}"
        repo="${name#*/}"
    else
        registry="docker.io"
        repo="$name"
        [[ "$repo" == */* ]] || repo="library/$repo"
    fi

    case "$registry" in
        docker.io)
            auth_url="https://auth.docker.io/token?service=registry.docker.io&scope=repository:${repo}:pull"
            api_host="registry-1.docker.io"
            ;;
        ghcr.io)
            auth_url="https://ghcr.io/token?scope=repository:${repo}:pull"
            api_host="ghcr.io"
            ;;
        *)
            return 2
            ;;
    esac

    local token code
    # --retry: разовый сбой реестра не должен останавливать установку
    token=$(curl -fsS --retry 3 --retry-all-errors --connect-timeout 15 --max-time 30 "$auth_url" 2>/dev/null \
            | grep -oP '"token"\s*:\s*"\K[^"]+' | head -n1) || true
    [[ -n "$token" ]] || return 2

    # Заголовок Accept со всеми форматами: мультиарх-образы отдают
    # индекс, обычные — манифест, без нужного типа реестр ответит 404
    code=$(curl -sS -o /dev/null -w '%{http_code}' -I --retry 3 --connect-timeout 15 --max-time 30 \
            -H "Authorization: Bearer $token" \
            -H "Accept: application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.docker.distribution.manifest.v2+json, application/vnd.oci.image.manifest.v1+json" \
            "https://${api_host}/v2/${repo}/manifests/${tag}" 2>/dev/null) || true

    case "$code" in
        200) return 0 ;;
        404) return 1 ;;
        *)   return 2 ;;
    esac
}

# ─────────────────────────────────────────────────
# Проверка, что все образы роли существуют
#
# Опечатка в REMNANODE_VERSION или исчезнувший тег иначе всплыли бы
# только на docker compose up — после того как сервер уже изменён.
# Если Docker установлен, проверяем через docker manifest inspect,
# иначе (полная установка) — через HTTP API реестра.
# Возвращает 1, если хотя бы одного образа нет или проверка не удалась.
# ─────────────────────────────────────────────────
check_role_images() {
    local image rc out failed=0

    while read -r image; do
        [[ -z "$image" ]] && continue

        if command -v docker &> /dev/null; then
            # Вторая попытка — на случай разового сбоя реестра; при
            # «no such manifest» повторять бессмысленно
            if out=$(docker manifest inspect "$image" 2>&1 >/dev/null) \
                || { [[ "$out" != *"no such manifest"* ]] && sleep 3 \
                     && out=$(docker manifest inspect "$image" 2>&1 >/dev/null); }; then
                log_info "✓ Образ $image есть в реестре"
                continue
            fi
            log_error "Образ $image не найден в реестре или реестр недоступен"
            log_error "   docker manifest inspect: $(head -n1 <<< "$out")"
            failed=1
            continue
        fi

        if ! command -v curl &> /dev/null; then
            log_error "Нечем проверить образ $image: нет ни docker, ни curl (apt install -y curl)"
            failed=1
            continue
        fi

        rc=0
        registry_tag_exists "$image" || rc=$?
        case "$rc" in
            0) log_info "✓ Образ $image есть в реестре" ;;
            1) log_error "Образа $image нет в реестре — проверьте тег"; failed=1 ;;
            *) log_error "Не удалось проверить образ $image: реестр недоступен"; failed=1 ;;
        esac
    done < <(role_images)

    return "$failed"
}

# ─────────────────────────────────────────────────
# Загрузка и проверка шаблонов роли
#
# Шаблоны скачиваются заранее, в предпроверках: при запуске через
# curl | bash из ветки, где шаблонов нет (или опечатка в
# REMNAWAVE_INSTALLER_REF), установка остановится до изменений,
# а не на шаге nginx. setup_nginx берёт уже проверенные файлы.
# Возвращает 1, если какой-то шаблон не получен или повреждён.
# ─────────────────────────────────────────────────
prefetch_role_templates() {
    role_has_site || return 0

    mkdir -p "$TEMPLATE_CACHE/nginx" "$TEMPLATE_CACHE/site"

    # Для скачивания нужен загрузчик; ensure_dependencies ещё не
    # запускался, поэтому выбираем из того, что уже есть
    if [[ -z "$DOWNLOADER" ]]; then
        if command -v curl &> /dev/null; then
            DOWNLOADER="curl"
        elif command -v wget &> /dev/null; then
            DOWNLOADER="wget"
        fi
    fi

    local conf_rel="nginx/${NODE_ROLE}.conf.tpl"
    local failed=0 marker

    if ! fetch_template "$conf_rel" "$TEMPLATE_CACHE/$conf_rel"; then
        failed=1
    else
        # Ошибка вида 404-страницы или обрезанный файл не должны
        # пройти как шаблон: проверяем обязательные подстановки
        local markers=("{{NODE_DOMAIN}}" "{{SITE_LOCAL_PORT}}" "http {")
        [[ "$NODE_ROLE" == "entry" ]] && markers+=("{{XRAY_LOCAL_PORT}}" "stream {")
        for marker in "${markers[@]}"; do
            if ! grep -qF "$marker" "$TEMPLATE_CACHE/$conf_rel"; then
                log_error "Шаблон $conf_rel повреждён: нет '$marker'"
                failed=1
            fi
        done
    fi

    if ! fetch_template site/index.html "$TEMPLATE_CACHE/site/index.html"; then
        failed=1
    elif ! grep -qi '</html>' "$TEMPLATE_CACHE/site/index.html"; then
        log_error "Шаблон site/index.html повреждён: нет </html>"
        failed=1
    fi

    (( failed == 0 )) && log_info "✓ Шаблоны роли получены и проверены"
    return "$failed"
}

# ─────────────────────────────────────────────────
# Предпроверки роли — до любых изменений на сервере
#
# Выполняются сразу после разбора параметров, чтобы занятый порт,
# чужой контейнер, несуществующий образ или недоступный шаблон
# обнаружились до долгой базовой установки.
# ─────────────────────────────────────────────────
preflight_role() {
    log "Предпроверки роли $NODE_ROLE..."
    local failed=0

    command -v ss &> /dev/null || { log_error "Нет утилиты ss (пакет iproute2)"; exit 1; }

    check_container_owner remnanode "$PROJECT_DIR" || failed=1
    if role_has_site; then
        check_container_owner nginx "$NGINX_DIR" || failed=1
        if [[ "$CERT_SOURCE" == "certwarden" ]]; then
            check_container_owner certwarden-client "$CERTWARDEN_DIR" || failed=1

            # Порт публикует docker-proxy, а не процесс контейнера,
            # поэтому «свой» слушатель определяем по контейнеру
            if [[ -n "$(port_listener_pids 5055)" ]] && ! container_running certwarden-client; then
                log_error "Порт 5055/tcp (CertWarden-клиент) занят:"
                ss -tlnp "sport = :5055" 2>/dev/null | tee -a "$LOG_FILE"
                failed=1
            fi
        fi
    fi

    # 443 на entry принимает nginx, на exit-direct — Xray внутри remnanode.
    # Локальные порты тоже проверяем: если сайт-заглушку не удастся
    # поднять на SITE_LOCAL_PORT, Reality потеряет target
    case "$NODE_ROLE" in
        entry)
            check_port_free 443 nginx || failed=1
            check_port_free 80 nginx || failed=1
            check_port_free "$SITE_LOCAL_PORT" nginx || failed=1
            check_port_free "$XRAY_LOCAL_PORT" remnanode || failed=1
            ;;
        exit-direct)
            check_port_free 443 remnanode || failed=1
            check_port_free 80 nginx || failed=1
            check_port_free "$SITE_LOCAL_PORT" nginx || failed=1
            ;;
    esac

    # Контейнеры, которые на старых нодах ставились вручную. Они
    # держат те же порты и перезапускают nginx под другим именем
    local legacy
    for legacy in remnawave-nginx certwardenclient; do
        if container_exists "$legacy"; then
            log_warning "Найден контейнер прежней ручной установки: $legacy"
            log_warning "После проверки новой схемы удалите его: docker rm -f $legacy"
        fi
    done

    check_role_images || failed=1
    prefetch_role_templates || failed=1

    if (( failed == 1 )); then
        log_error "Предпроверки не пройдены — на сервере ничего не изменено"
        log_error "Исправьте пункты выше и запустите скрипт снова"
        exit 1
    fi
    log_info "✓ Предпроверки пройдены"
}

# ─────────────────────────────────────────────────
# Установка конфига с резервной копией
#
# Если файл не изменился — ничего не делает и возвращает 1.
# Иначе сохраняет старую версию в <компонент>/backup-<дата>/
# и записывает новую. Запись идёт в существующий файл (cat >),
# а не через mv: файл может быть смонтирован в контейнер по
# отдельности, и после mv контейнер продолжал бы видеть старый.
#
# Резервные копии могут содержать секреты (SECRET_KEY, ключи
# CertWarden), а старый файл мог лежать с правами 644 — поэтому
# каталог копий создаётся с 700, а сама копия получает 600.
#
# Аргументы: временный файл, целевой путь, директория компонента,
# необязательные права целевого файла (выставляются до записи).
# ─────────────────────────────────────────────────
install_config() {
    local src="$1" dest="$2" comp_dir="$3" mode="${4:-}"

    if [[ -f "$dest" ]] && cmp -s "$src" "$dest"; then
        rm -f "$src"
        [[ -n "$mode" ]] && chmod "$mode" "$dest"
        log_info "Без изменений: $dest"
        return 1
    fi

    if [[ -f "$dest" ]]; then
        local backup_dir="$comp_dir/backup-$BACKUP_STAMP"
        local backup_file
        backup_file="$backup_dir/$(basename "$dest")"
        mkdir -p "$backup_dir"
        chmod 700 "$backup_dir"
        install -m 600 "$dest" "$backup_file"
        log_info "Старая версия сохранена: $backup_file"
    fi

    # Права — до записи, чтобы секреты не полежали с правами по умолчанию
    if [[ -n "$mode" ]]; then
        [[ -e "$dest" ]] || : > "$dest"
        chmod "$mode" "$dest"
    fi
    cat "$src" > "$dest"
    rm -f "$src"
    log_info "✓ Записан: $dest"
    return 0
}

# ─────────────────────────────────────────────────
# Значение для YAML в одинарных кавычках
#
# Секреты могут содержать любые символы. В одинарных кавычках
# YAML экранирует только саму кавычку (''), а $ удваивается,
# чтобы docker compose не принял его за подстановку переменной.
# ─────────────────────────────────────────────────
yaml_quote() {
    local v="$1"
    v="${v//\'/\'\'}"
    v="${v//\$/\$\$}"
    printf "'%s'" "$v"
}

# ─────────────────────────────────────────────────
# Получение шаблона из репозитория
#
# Если скрипт запущен из клона, шаблон берётся рядом со скриптом.
# При запуске через curl | bash локальной копии нет — шаблон
# скачивается с GitHub из ветки INSTALLER_REF.
# Аргументы: путь внутри templates/, путь назначения.
# ─────────────────────────────────────────────────
fetch_template() {
    local rel="$1" dest="$2"
    local script_path="${BASH_SOURCE[0]:-}"

    if [[ -f "$script_path" ]]; then
        local local_tpl
        local_tpl="$(cd "$(dirname "$script_path")" && pwd)/templates/$rel"
        if [[ -f "$local_tpl" ]]; then
            cp "$local_tpl" "$dest"
            return 0
        fi
    fi

    if [[ -z "$DOWNLOADER" ]]; then
        log_error "Шаблон $rel не найден рядом со скриптом, а скачать его нечем: нужен curl или wget"
        return 1
    fi
    if ! download_file "$TEMPLATES_URL/$rel" "$dest" >> "$LOG_FILE" 2>&1; then
        rm -f "$dest"
        log_error "Не удалось получить шаблон $rel ($TEMPLATES_URL/$rel)"
        log_error "Для проверки неслитой ветки укажите её: REMNAWAVE_INSTALLER_REF=dev"
        return 1
    fi
}

# ─────────────────────────────────────────────────
# Проверка сертификата в /opt/certs
#
# Файлы есть и читаются, сертификат не просрочен, ключ от него,
# домен ноды входит в SAN. Возвращает 1 при первой же проблеме,
# сообщение уже выведено.
# ─────────────────────────────────────────────────
check_cert_files() {
    local chain="$CERTS_DIR/$CERT_FULLCHAIN" key="$CERTS_DIR/$CERT_PRIVKEY"

    if [[ ! -s "$chain" || ! -s "$key" ]]; then
        log_error "Нет файлов сертификата: нужны $chain и $key"
        return 1
    fi
    if ! openssl x509 -in "$chain" -noout &> /dev/null; then
        log_error "$chain не читается как сертификат PEM"
        return 1
    fi
    if ! openssl pkey -in "$key" -noout &> /dev/null; then
        log_error "$key не читается как приватный ключ PEM"
        return 1
    fi
    if ! openssl x509 -in "$chain" -noout -checkend 0 &> /dev/null; then
        log_error "Сертификат $chain просрочен ($(openssl x509 -in "$chain" -noout -enddate))"
        return 1
    fi

    local cert_pub key_pub
    cert_pub=$(openssl x509 -in "$chain" -noout -pubkey 2>/dev/null)
    key_pub=$(openssl pkey -in "$key" -pubout 2>/dev/null)
    if [[ "$cert_pub" != "$key_pub" ]]; then
        log_error "Ключ $key не подходит к сертификату $chain"
        return 1
    fi

    if ! openssl x509 -in "$chain" -noout -checkhost "$NODE_DOMAIN" 2>/dev/null | grep -q "does match"; then
        log_error "Сертификат не покрывает домен $NODE_DOMAIN"
        log_error "SAN: $(openssl x509 -in "$chain" -noout -ext subjectAltName 2>/dev/null | tail -n +2 | xargs)"
        return 1
    fi

    if ! openssl x509 -in "$chain" -noout -checkend $(( 14 * 86400 )) &> /dev/null; then
        log_warning "Сертификат истекает меньше чем через 14 дней"
    fi
    return 0
}

# ─────────────────────────────────────────────────
# CertWarden-клиент
#
# Повторяет схему с рабочих серверов: клиент пишет файлы в
# /opt/certwarden/certs внутри контейнера (это /opt/certs на хосте)
# и после продления перезапускает контейнер nginx через docker.sock.
#
# remnanode не перезапускается: Xray сам перечитывает файлы
# сертификата раз в час, а перезапуск рвёт все подключения.
# ─────────────────────────────────────────────────
deploy_certwarden() {
    log "Настройка CertWarden-клиента..."

    mkdir -p "$CERTWARDEN_DIR"
    chmod 700 "$CERTWARDEN_DIR"   # в compose-файле секреты

    local tmp="$CERTWARDEN_DIR/.docker-compose.yml.tmp"
    : > "$tmp"
    chmod 600 "$tmp"

# Heredoc специально начинается с колонки 0
cat >> "$tmp" <<EOF
# Сгенерировано setup_remnawave_node.sh — содержит секреты, chmod 600
services:
  certwarden-client:
    container_name: certwarden-client
    image: ${CERTWARDEN_IMAGE}
    restart: unless-stopped
    ports:
      - "127.0.0.1:5055:5055"
    environment:
      TZ: $(yaml_quote "$TZ")
      CW_CLIENT_SERVER_ADDRESS: $(yaml_quote "$CW_CLIENT_SERVER_ADDRESS")
      CW_CLIENT_AES_KEY_BASE64: $(yaml_quote "$CW_CLIENT_AES_KEY_BASE64")
      CW_CLIENT_KEY_NAME: $(yaml_quote "$CW_CLIENT_KEY_NAME")
      CW_CLIENT_KEY_APIKEY: $(yaml_quote "$CW_CLIENT_KEY_APIKEY")
      CW_CLIENT_CERT_NAME: $(yaml_quote "$CW_CLIENT_CERT_NAME")
      CW_CLIENT_CERT_APIKEY: $(yaml_quote "$CW_CLIENT_CERT_APIKEY")
      CW_CLIENT_FILE_UPDATE_TIME_START: $(yaml_quote "$CW_CLIENT_FILE_UPDATE_TIME_START")
      CW_CLIENT_FILE_UPDATE_TIME_END: $(yaml_quote "$CW_CLIENT_FILE_UPDATE_TIME_END")
      CW_CLIENT_FILE_UPDATE_DAYS_OF_WEEK: $(yaml_quote "$CW_CLIENT_FILE_UPDATE_DAYS_OF_WEEK")
      CW_CLIENT_CERT_PATH: '/opt/certwarden/certs'
      CW_CLIENT_CERTCHAIN_PEM_FILENAME: '${CERT_FULLCHAIN}'
      CW_CLIENT_KEY_PEM_FILENAME: '${CERT_PRIVKEY}'
      CW_CLIENT_RESTART_DOCKER_CONTAINER0: 'nginx'
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - ${CERTS_DIR}:/opt/certwarden/certs
EOF

    local compose="$CERTWARDEN_DIR/docker-compose.yml"
    install_config "$tmp" "$compose" "$CERTWARDEN_DIR" 600 || true

    if ! docker compose -f "$compose" up -d >> "$LOG_FILE" 2>&1; then
        log_error "Не удалось запустить certwarden-client, подробности: $LOG_FILE"
        exit 1
    fi
    log_info "✓ certwarden-client запущен"

    # При старте клиент сам забирает текущие ключ и сертификат
    # с сервера. Ждём появления файлов.
    local waited=0 max_wait=120
    while [[ ! -s "$CERTS_DIR/$CERT_FULLCHAIN" || ! -s "$CERTS_DIR/$CERT_PRIVKEY" ]]; do
        if (( waited >= max_wait )); then
            log_error "За ${max_wait}с CertWarden-клиент не записал $CERT_FULLCHAIN и $CERT_PRIVKEY в $CERTS_DIR"
            log_error "Логи клиента: docker logs certwarden-client"
            log_error "Проверьте CW_CLIENT_* в $ENV_FILE и доступность $CW_CLIENT_SERVER_ADDRESS"
            exit 1
        fi
        sleep 3
        waited=$(( waited + 3 ))
    done
    log_info "✓ Файлы сертификата получены от CertWarden"
}

# ─────────────────────────────────────────────────
# Сертификат для ролей entry и exit-direct
# ─────────────────────────────────────────────────
setup_certificates() {
    log "Сертификат ($CERT_SOURCE)..."

    mkdir -p "$CERTS_DIR"
    chmod 755 "$CERTS_DIR"

    if [[ "$CERT_SOURCE" == "certwarden" ]]; then
        deploy_certwarden
    fi

    until check_cert_files; do
        if [[ "$CERT_SOURCE" == "certwarden" ]] || (( NON_INTERACTIVE == 1 )); then
            echo ""
            log_error "Положите сертификат (wildcard или на $NODE_DOMAIN) в $CERTS_DIR:"
            log_error "   $CERTS_DIR/$CERT_FULLCHAIN  — сертификат с цепочкой"
            log_error "   $CERTS_DIR/$CERT_PRIVKEY    — приватный ключ"
            log_error "и запустите скрипт снова (можно с --role-only)"
            exit 1
        fi
        echo ""
        echo -e "${YELLOW}Положите файлы в $CERTS_DIR:${NC}"
        echo -e "   $CERTS_DIR/$CERT_FULLCHAIN  — сертификат с цепочкой"
        echo -e "   $CERTS_DIR/$CERT_PRIVKEY    — приватный ключ"
        read -rp "$(echo -e "Нажмите ${GREEN}Enter${NC}, когда файлы будут на месте (Ctrl+C — отмена): ")" _ < /dev/tty
    done

    chmod 600 "$CERTS_DIR/$CERT_PRIVKEY"
    chmod 644 "$CERTS_DIR/$CERT_FULLCHAIN"

    log "✓ Сертификат в порядке"
    log_info "Действует до: $(openssl x509 -in "$CERTS_DIR/$CERT_FULLCHAIN" -noout -enddate | cut -d= -f2)"
    log_info "SAN: $(openssl x509 -in "$CERTS_DIR/$CERT_FULLCHAIN" -noout -ext subjectAltName 2>/dev/null | tail -n +2 | xargs)"
}

# ─────────────────────────────────────────────────
# nginx: SNI-роутер и/или сайт-заглушка
# ─────────────────────────────────────────────────
setup_nginx() {
    log "Настройка nginx ($NODE_ROLE)..."

    mkdir -p "$NGINX_DIR/html"

    # Сайт-заглушка — только в пустую папку: свой сайт владельца не трогаем
    if [[ -z "$(ls -A "$NGINX_DIR/html" 2>/dev/null)" ]]; then
        cp "$TEMPLATE_CACHE/site/index.html" "$NGINX_DIR/html/index.html"
        chmod 644 "$NGINX_DIR/html/index.html"
        log_info "✓ Сайт-заглушка положен в $NGINX_DIR/html/"
    else
        log_info "В $NGINX_DIR/html/ уже есть файлы — сайт не трогаем"
    fi

    # Шаблон → конфиг. Значения проверены в resolve_params (домен —
    # только [a-z0-9.-], порты — числа), поэтому sed безопасен
    local tmp_conf="$NGINX_DIR/.nginx.conf.tmp"
    # Шаблон получен и проверен в предпроверках (prefetch_role_templates)
    cp "$TEMPLATE_CACHE/nginx/${NODE_ROLE}.conf.tpl" "$tmp_conf"
    sed -i \
        -e "s/{{NODE_DOMAIN}}/${NODE_DOMAIN}/g" \
        -e "s/{{XRAY_LOCAL_PORT}}/${XRAY_LOCAL_PORT}/g" \
        -e "s/{{SITE_LOCAL_PORT}}/${SITE_LOCAL_PORT}/g" \
        "$tmp_conf"
    if grep -q '{{' "$tmp_conf"; then
        log_error "В шаблоне nginx остались неподставленные значения: $(grep -o '{{[A-Z_]*}}' "$tmp_conf" | sort -u | xargs)"
        exit 1
    fi

    # Проверяем конфиг до установки, в одноразовом контейнере без сети
    if ! docker run --rm --network none \
            -v "$tmp_conf:/etc/nginx/nginx.conf:ro" \
            -v "$CERTS_DIR:/etc/nginx/ssl:ro" \
            "$NGINX_IMAGE" nginx -t >> "$LOG_FILE" 2>&1; then
        log_error "nginx -t не принял новый конфиг (он сохранён в $tmp_conf), подробности: $LOG_FILE"
        exit 1
    fi
    log_info "✓ nginx -t: конфиг корректен"

    NGINX_CONF_CHANGED=0
    if install_config "$tmp_conf" "$NGINX_DIR/nginx.conf" "$NGINX_DIR"; then
        NGINX_CONF_CHANGED=1
    fi

    local tmp_compose="$NGINX_DIR/.docker-compose.yml.tmp"
cat > "$tmp_compose" <<EOF
# Сгенерировано setup_remnawave_node.sh
services:
  nginx:
    container_name: nginx
    image: ${NGINX_IMAGE}
    network_mode: host
    restart: always
    volumes:
      - ${NGINX_DIR}/nginx.conf:/etc/nginx/nginx.conf:ro
      - ${NGINX_DIR}/html:/usr/share/nginx/html:ro
      # Папкой, а не отдельными файлами: CertWarden заменяет файлы,
      # и смонтированный по отдельности файл показывал бы старую версию
      - ${CERTS_DIR}:/etc/nginx/ssl:ro
EOF
    install_config "$tmp_compose" "$NGINX_DIR/docker-compose.yml" "$NGINX_DIR" || true

    local was_running=0
    container_running nginx && was_running=1

    if ! docker compose -f "$NGINX_DIR/docker-compose.yml" up -d >> "$LOG_FILE" 2>&1; then
        log_error "Не удалось запустить nginx, подробности: $LOG_FILE и docker logs nginx"
        exit 1
    fi

    # Контейнер уже работал, а поменялся только nginx.conf — compose
    # его не пересоздаст. reload, в отличие от restart, не рвёт
    # текущие подключения через stream
    if (( was_running == 1 && NGINX_CONF_CHANGED == 1 )); then
        if docker exec nginx nginx -s reload >> "$LOG_FILE" 2>&1; then
            log_info "✓ nginx перечитал конфиг (reload)"
        else
            log_warning "nginx -s reload не удался — проверьте docker logs nginx"
        fi
    fi
    log "✓ nginx запущен"
}

# ─────────────────────────────────────────────────
# SECRET_KEY из существующего docker-compose.yml
#
# Повторный запуск и --role-only на рабочей ноде не должны
# затирать действующий ключ плейсхолдером.
# ─────────────────────────────────────────────────
existing_secret_key() {
    local compose="$PROJECT_DIR/docker-compose.yml" key
    [[ -f "$compose" ]] || return 0

    # Поддерживаем обе записи: "- SECRET_KEY=..." и "SECRET_KEY: ..."
    key=$(grep -oP '^\s*-?\s*SECRET_KEY\s*[=:]\s*\K.*' "$compose" | head -n1 || true)
    key="${key%$'\r'}"
    key="${key#[\"\']}"
    key="${key%[\"\']}"
    [[ "$key" == "REPLACE_WITH_SECRET_KEY_FROM_PANEL" ]] && key=""
    printf '%s' "$key"
}

# ─────────────────────────────────────────────────
# Генерация docker-compose.yml для Remnawave Node
#
# Создаётся шаблон на основе официального docker-compose remnanode.
# SECRET_KEY запрашивается у пользователя — его выдаёт панель Remnawave
# при создании ноды. Использует network_mode: host, поэтому явные port
# mappings не нужны — порты Xray задаёт профиль в панели.
# ─────────────────────────────────────────────────
generate_docker_compose() {
    log "Генерация docker-compose.yml для Remnawave Node..."

    mkdir -p "$PROJECT_DIR"
    chmod 700 "$PROJECT_DIR"   # compose-файл и его копии содержат SECRET_KEY

    if [[ -z "$SECRET_KEY" ]]; then
        SECRET_KEY=$(existing_secret_key)
        [[ -n "$SECRET_KEY" ]] && log_info "SECRET_KEY взят из существующего $PROJECT_DIR/docker-compose.yml"
    fi

    # SECRET_KEY может прийти из конфигурации или окружения.
    # Если его нет — спрашиваем, а в неинтерактивном режиме
    # оставляем плейсхолдер: ключ выдаётся панелью при создании
    # ноды, поэтому на момент раскатки его часто ещё не существует.
    if [[ -z "$SECRET_KEY" ]] && (( NON_INTERACTIVE == 0 )); then
        echo ""
        echo -e "${CYAN}──────────── SECRET_KEY для Remnawave Node ────────────${NC}"
        echo -e "${YELLOW}SECRET_KEY выдаётся панелью Remnawave при создании ноды.${NC}"
        echo -e "${YELLOW}Если ключ уже есть — вставьте его сейчас.${NC}"
        echo -e "${YELLOW}Или нажмите Enter, чтобы заполнить вручную позже.${NC}"
        echo ""

        read -rp "$(echo -e "${YELLOW}SECRET_KEY${NC} (или Enter для пропуска): ")" SECRET_KEY < /dev/tty
    fi

    local secret_key="$SECRET_KEY"
    if [[ -z "$secret_key" ]]; then
        secret_key="REPLACE_WITH_SECRET_KEY_FROM_PANEL"
        log_warning "SECRET_KEY не задан. Не забудьте заполнить его в $PROJECT_DIR/docker-compose.yml"
    fi

    # exit-direct: сертификат для Hysteria2 и прямых TLS-подключений.
    # Монтируется папка целиком — см. комментарий в compose nginx
    local ssl_volume=""
    if [[ "$NODE_ROLE" == "exit-direct" ]]; then
        ssl_volume="      - ${CERTS_DIR}:${REMNANODE_SSL_DIR}:ro"
    fi

    local tmp="$PROJECT_DIR/.docker-compose.yml.tmp"
    : > "$tmp"
    chmod 600 "$tmp"

# Heredoc специально начинается с колонки 0.
# network_mode: host — контейнер напрямую использует сетевой стек хоста,
# поэтому порты открываются через UFW (уже настроен выше), а не через
# Docker port mapping.
cat >> "$tmp" <<EOF
# Сгенерировано setup_remnawave_node.sh, роль: ${NODE_ROLE}
services:
  remnanode:
    container_name: remnanode
    hostname: remnanode
    image: remnawave/node:${REMNANODE_VERSION}
    network_mode: host
    restart: always
    cap_add:
      - NET_ADMIN
    ulimits:
      nofile:
        soft: 1048576
        hard: 1048576
    environment:
      - NODE_PORT=${NODE_PORT}
      - SECRET_KEY=${secret_key}
    volumes:
      - /var/log/remnanode:/var/log/remnanode
${ssl_volume}
EOF
    # Пустая строка на месте ssl_volume для других ролей не нужна
    [[ -z "$ssl_volume" ]] && sed -i '$ { /^$/d }' "$tmp"

    local compose="$PROJECT_DIR/docker-compose.yml"
    install_config "$tmp" "$compose" "$PROJECT_DIR" 600 || true   # в файле SECRET_KEY

    if [[ "$secret_key" == "REPLACE_WITH_SECRET_KEY_FROM_PANEL" ]]; then
        log_warning "Перед запуском замените SECRET_KEY в $compose и выполните:"
        log_warning "   cd $PROJECT_DIR && docker compose up -d"
        return 0
    fi

    # up -d пересоздаёт контейнер, только если compose изменился
    if docker compose -f "$compose" up -d >> "$LOG_FILE" 2>&1; then
        log "✓ remnanode запущен (remnawave/node:${REMNANODE_VERSION})"
    else
        log_error "Не удалось запустить remnanode, подробности: $LOG_FILE и docker logs remnanode"
        exit 1
    fi
}

# ─────────────────────────────────────────────────
# Итоговая проверка роли
#
# Не останавливает скрипт: всё уже установлено, задача — показать,
# что работает, а что нет. Итог — число непройденных пунктов.
# ─────────────────────────────────────────────────
VERIFY_FAILED=0

report_check() {
    local ok="$1" text="$2"
    if [[ "$ok" == "ok" ]]; then
        echo -e "   ${GREEN}✓${NC} $text" | tee -a "$LOG_FILE"
    else
        echo -e "   ${RED}✗${NC} $text" | tee -a "$LOG_FILE"
        VERIFY_FAILED=$(( VERIFY_FAILED + 1 ))
    fi
}

# TLS-рукопожатие с сайтом-заглушкой. Проверяет то, что нужно
# Reality от target: TLS 1.3, ALPN h2 и валидный для домена сертификат.
# Аргументы: адрес:порт, SNI. Код возврата 0 — всё в порядке.
check_site_tls() {
    local target="$1" sni="$2" out
    out=$(echo | timeout 10 openssl s_client -connect "$target" -servername "$sni" \
            -tls1_3 -alpn h2 -verify_hostname "$NODE_DOMAIN" 2>&1 || true)
    grep -q 'Verify return code: 0 (ok)' <<< "$out" \
        && grep -q 'ALPN protocol: h2' <<< "$out"
}

verify_role() {
    VERIFY_FAILED=0
    echo ""
    echo -e "${CYAN}──────────────── Итоговая проверка (роль ${NODE_ROLE}) ────────────────${NC}"

    # Контейнеры роли
    local containers=(remnanode) c
    role_has_site && containers+=(nginx)
    role_has_site && [[ "$CERT_SOURCE" == "certwarden" ]] && containers+=(certwarden-client)
    for c in "${containers[@]}"; do
        if container_running "$c"; then
            report_check ok "контейнер $c запущен"
        elif [[ "$c" == "remnanode" && -z "$SECRET_KEY" ]]; then
            report_check fail "контейнер remnanode не запущен: нет SECRET_KEY (впишите в $PROJECT_DIR/docker-compose.yml)"
        else
            report_check fail "контейнер $c не запущен (docker logs $c)"
        fi
    done

    # Слушатели и сайт
    local ss_out
    case "$NODE_ROLE" in
        entry)
            ss_out=$(ss -Htlnp 'sport = :443' 2>/dev/null || true)
            if grep -qE '(0\.0\.0\.0|\*):443 ' <<< "$ss_out" && grep -q nginx <<< "$ss_out"; then
                report_check ok "nginx слушает 0.0.0.0:443"
            else
                report_check fail "nginx не слушает 0.0.0.0:443"
            fi
            ss_out=$(ss -Htlnp 'sport = :80' 2>/dev/null || true)
            if grep -qE '(0\.0\.0\.0|\*):80 ' <<< "$ss_out" && grep -q nginx <<< "$ss_out"; then
                report_check ok "nginx слушает 0.0.0.0:80"
            else
                report_check fail "nginx не слушает 0.0.0.0:80"
            fi
            if check_site_tls "127.0.0.1:$SITE_LOCAL_PORT" "$NODE_DOMAIN"; then
                report_check ok "сайт на 127.0.0.1:$SITE_LOCAL_PORT: TLS 1.3, h2, сертификат валиден для $NODE_DOMAIN"
            else
                report_check fail "сайт на 127.0.0.1:$SITE_LOCAL_PORT не прошёл проверку TLS 1.3 + h2 + сертификат"
            fi
            # Чужой SNI на 443 должен уходить на сайт, а не в Xray
            if check_site_tls "127.0.0.1:443" "example.com"; then
                report_check ok "443 с чужим SNI отдаёт сайт-заглушку"
            else
                report_check fail "443 с чужим SNI не отдаёт сайт-заглушку"
            fi
            ;;
        exit-direct)
            if check_site_tls "127.0.0.1:$SITE_LOCAL_PORT" "$NODE_DOMAIN"; then
                report_check ok "сайт на 127.0.0.1:$SITE_LOCAL_PORT: TLS 1.3, h2, сертификат валиден для $NODE_DOMAIN"
            else
                report_check fail "сайт на 127.0.0.1:$SITE_LOCAL_PORT не прошёл проверку TLS 1.3 + h2 + сертификат"
            fi
            if container_running remnanode \
                && docker exec remnanode test -r "$REMNANODE_SSL_DIR/$CERT_FULLCHAIN" 2>/dev/null \
                && docker exec remnanode test -r "$REMNANODE_SSL_DIR/$CERT_PRIVKEY" 2>/dev/null; then
                report_check ok "сертификат виден в remnanode: $REMNANODE_SSL_DIR/"
            else
                report_check fail "сертификат не виден в remnanode по пути $REMNANODE_SSL_DIR/"
            fi
            ;;
    esac

    # Порт моста не должен быть разрешён в UFW
    if ufw status 2>/dev/null | grep -qE "^${BRIDGE_PORT}(/(tcp|udp))?[[:space:]]"; then
        report_check fail "${BRIDGE_PORT} разрешён в UFW — мост должен идти только через NetBird (ufw status numbered)"
    else
        report_check ok "${BRIDGE_PORT} в UFW не разрешён"
    fi

    # NetBird
    if netbird status 2>/dev/null | grep -q 'Management: Connected'; then
        report_check ok "NetBird подключён: IP ${NETBIRD_IP:-?}, FQDN ${NETBIRD_FQDN:-?}"
    else
        report_check fail "NetBird не подключён (netbird status)"
    fi

    echo ""
    if (( VERIFY_FAILED == 0 )); then
        log "✓ Все проверки пройдены"
    else
        log_warning "Не пройдено проверок: $VERIFY_FAILED — см. пункты с ✗"
    fi
}

# ─────────────────────────────────────────────────
# Что сделать в панели для этой роли
# ─────────────────────────────────────────────────
show_panel_hints() {
    echo -e "${BLUE}📝 Что сделать в панели (роль ${NODE_ROLE}):${NC}"
    echo ""
    echo -e "  ${YELLOW}1.${NC} Nodes → Management → [+]"
    echo -e "     Node Address: ${GREEN}${NETBIRD_IP:-<netbird_ip>}${NC}  (NetBird IP, не публичный)"
    echo -e "     Node Port:    ${GREEN}$NODE_PORT${NC}"
    if [[ -z "$SECRET_KEY" ]]; then
        echo -e "     Скопируйте SECRET_KEY в ${GREEN}$PROJECT_DIR/docker-compose.yml${NC}, затем:"
        echo -e "     ${GREEN}cd $PROJECT_DIR && docker compose up -d${NC}"
    fi
    echo ""

    case "$NODE_ROLE" in
        entry)
            echo -e "  ${YELLOW}2.${NC} Config Profile: ${GREEN}entry-ru${NC}"
            echo -e "  ${YELLOW}3.${NC} В инбаунде ${GREEN}entry-selfsteal${NC} добавьте ${GREEN}$NODE_DOMAIN${NC} в serverNames"
            echo -e "  ${YELLOW}4.${NC} Создайте хост: адрес ${GREEN}$NODE_DOMAIN${NC}, SNI ${GREEN}$NODE_DOMAIN${NC} — указать явно"
            ;;
        exit)
            echo -e "  ${YELLOW}2.${NC} Config Profile: ${GREEN}exit${NC}"
            echo -e "  ${YELLOW}3.${NC} В NetBird переименуйте пир ${GREEN}${NETBIRD_FQDN:-этого сервера}${NC} в ${GREEN}exit-<страна><номер>${NC}"
            echo -e "  ${YELLOW}4.${NC} В профиль ${GREEN}entry-ru${NC} добавьте аутбаунд ${GREEN}to-...${NC} на эту ноду"
            echo -e "  ${YELLOW}5.${NC} Создайте служебного пользователя ${GREEN}_bridge-...${NC} в скваде ${GREEN}bridges${NC}"
            ;;
        exit-direct)
            echo -e "  ${YELLOW}2.${NC} Config Profile: ${GREEN}exit-direct${NC}"
            echo -e "  ${YELLOW}3.${NC} Создайте хосты для прямых подключений (адрес ${GREEN}$NODE_DOMAIN${NC})"
            echo -e "     Сертификат в профиле: ${GREEN}$REMNANODE_SSL_DIR/$CERT_FULLCHAIN${NC} и ${GREEN}$CERT_PRIVKEY${NC}"
            ;;
    esac
    echo ""
}

# ─────────────────────────────────────────────────
# Финальные инструкции
# ─────────────────────────────────────────────────
show_next_steps() {
    echo ""
    echo -e "${GREEN}╔════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║           Установка Remnawave Node завершена!                      ║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════════════════════════════════════╝${NC}"
    echo ""

    echo -e "${BLUE}🌐 Сетевая информация:${NC}"
    if [[ -n "$NETBIRD_IP" ]]; then
        echo -e "   NetBird IP: ${GREEN}$NETBIRD_IP${NC}  ${YELLOW}← укажите в панели при создании ноды${NC}"
    else
        echo -e "   NetBird IP: ${RED}не определён${NC} — запустите: netbird status"
    fi
    echo ""

    if (( ROLE_ONLY == 0 )); then
        echo -e "${BLUE}📊 Мониторинг (linux-${ARCH_SUFFIX}):${NC}"
        echo -e "   ✓ cAdvisor v${CADVISOR_VERSION}       → 127.0.0.1:9101"
        echo -e "   ✓ Node Exporter v${NODE_EXPORTER_VERSION}  → 127.0.0.1:9100"
        echo -e "   ✓ vmagent v${VMAGENT_VERSION}       → 127.0.0.1:8429"
        echo -e "   Instance label: ${GREEN}$INSTANCE_NAME${NC}"
        echo -e "   Remote write:   ${GREEN}$VICTORIA_METRICS_URL${NC}"
        echo ""
    fi

    echo -e "${BLUE}🔒 Firewall (UFW), роль ${NODE_ROLE}:${NC}"
    echo -e "   ✓ SSH ${SSH_PORT_LIST[*]}          — разрешён (TCP)"
    echo -e "   ✓ NODE_PORT $NODE_PORT  — только для $PANEL_NETBIRD_IP (NetBird, TCP)"
    if [[ -n "$(role_public_ports)" ]]; then
        echo -e "   ✓ Для всех: $(role_public_ports)"
    else
        echo -e "   ✓ Публичных портов нет"
    fi
    echo -e "   ✓ ${BRIDGE_PORT}/tcp (мост) — не открыт, работает через NetBird"
    echo ""

    show_panel_hints

    echo -e "${BLUE}🔍 Полезные команды:${NC}"
    (( ROLE_ONLY == 0 )) && echo -e "   systemctl status cadvisor nodeexporter vmagent"
    echo -e "   docker logs -f remnanode"
    role_has_site && echo -e "   docker logs -f nginx"
    [[ "$CERT_SOURCE" == "certwarden" ]] && role_has_site && echo -e "   docker logs -f certwarden-client"
    echo -e "   ufw status numbered"
    echo -e "   netbird status"
    echo ""
    echo -e "${BLUE}📄 Лог установки:${NC} $LOG_FILE"
    if [[ -f "$ENV_FILE" ]]; then
        echo -e "${BLUE}⚙️  Конфигурация:${NC}  $ENV_FILE"
        echo -e "   Повтор установки без вопросов:"
        echo -e "   ${GREEN}sudo $0 --config $ENV_FILE --non-interactive${NC}"
    fi
    echo ""
}

# ─────────────────────────────────────────────────
# Точка входа
# ─────────────────────────────────────────────────
main() {
    # Аргументы разбираем до всего остального, чтобы --help
    # работал без прав root
    parse_args "$@"

    echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}   Remnawave Node Auto-Installer v4.0.0                    ${NC}"
    echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"
    echo ""

    # Проверка root идёт первой: touch /var/log/... без прав выдал бы
    # "Permission denied" вместо понятного сообщения
    check_root
    touch "$LOG_FILE"
    init_tmp_dir

    load_env_file
    detect_arch
    resolve_params

    (( ROLE_ONLY == 1 )) && check_role_only_prereqs

    # Занятые порты и чужие контейнеры — до любых изменений
    preflight_role

    # Параметры собраны и проверены — сохраняем их для повторного
    # запуска. В неинтерактивном режиме файлом управляет пользователь,
    # поэтому не трогаем его.
    if (( NON_INTERACTIVE == 0 )); then
        save_env_file
    fi

    log "Начало установки (роль $NODE_ROLE$( (( ROLE_ONLY == 1 )) && echo ', только ролевая часть'))..."

    if (( ROLE_ONLY == 0 )); then
        # Базовые компоненты
        update_system
        # После apt update, но до первой загрузки: списки пакетов уже
        # актуальны, а недостающий загрузчик обнаружится сразу, а не
        # на середине установки
        ensure_dependencies
        install_netbird
        setup_netbird
        install_docker
        create_project_dir

        # Мониторинг
        create_monitoring_dirs
        install_all_monitoring_binaries  # ← параллельная загрузка всех трёх
        create_monitoring_configs
        start_monitoring_services
    else
        ensure_dependencies
        create_project_dir
    fi

    # Безопасность
    configure_firewall

    # Роль: сертификат и nginx — до remnanode, чтобы на exit-direct
    # Xray сразу увидел файлы сертификата
    if role_has_site; then
        setup_certificates
        setup_nginx
    fi

    # docker-compose.yml для ноды
    generate_docker_compose

    # Повторное сохранение: SSH_PORTS и SECRET_KEY становятся
    # известны уже после первого сохранения
    if (( NON_INTERACTIVE == 0 )); then
        save_env_file
    fi

    # Финал
    get_netbird_ip
    verify_role
    show_next_steps

    log "Установка завершена успешно."
}

main "$@"
