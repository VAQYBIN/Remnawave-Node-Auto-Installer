#!/bin/bash

#####################################################
# Скрипт автоматической настройки Remnawave Node
# Версия: 3.2.1
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
# Поддерживает запуск через pipe:
#   curl ... | sudo bash
#   sudo bash <(curl ...)
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

# Временная директория для параллельных загрузок
TMP_DIR="/tmp/remnawave_setup_$$"

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
#   NETBIRD_SETUP_KEY=xxx sudo bash setup_remnawave_node.sh
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
XRAY_PORT="${XRAY_PORT:-}"
PANEL_NETBIRD_IP="${PANEL_NETBIRD_IP:-}"   # NetBird IP панели (100.x.x.x), а не публичный
SSH_PORTS="${SSH_PORTS:-}"                 # строка "22 2233"; пусто — автоопределение
SECRET_KEY="${SECRET_KEY:-}"               # выдаётся панелью при создании ноды

# Значения по умолчанию для необязательных параметров
DEFAULT_NODE_PORT="2222"
DEFAULT_XRAY_PORT="443"

# Вычисляются в процессе работы
NETBIRD_IP=""
ARCH_SUFFIX=""        # Определяется автоматически
SSH_PORT_LIST=()      # Итоговый список портов для правил UFW
DOWNLOADER=""         # "curl" или "wget" — выбирается по факту наличия

# ─────────────────────────────────────────────────
# Режим работы
# ─────────────────────────────────────────────────
ENV_FILE="${REMNAWAVE_ENV_FILE:-/opt/remnawave-installer/.env}"
NON_INTERACTIVE=0
SAVE_ENV=1

# Белый список параметров, распознаваемых в файле конфигурации.
# Всё остальное игнорируется с предупреждением — это ловит опечатки
# и не даёт файлу конфигурации переопределить внутренние переменные
# скрипта (пути, версии компонентов, режим работы).
ENV_KEYS=(
    NETBIRD_SETUP_KEY
    INSTANCE_NAME
    VICTORIA_METRICS_URL
    NODE_PORT
    XRAY_PORT
    PANEL_NETBIRD_IP
    SSH_PORTS
    SECRET_KEY
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
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT

# ─────────────────────────────────────────────────
# Справка по использованию
# ─────────────────────────────────────────────────
usage() {
    cat <<'USAGE'
Remnawave Node Auto-Installer

Использование:
  sudo ./setup_remnawave_node.sh [ОПЦИИ]
  sudo bash <(curl -fsSL git.new/remnawave-setup) [ОПЦИИ]

Опции:
  -c, --config PATH     Путь к файлу конфигурации
                        (по умолчанию: /opt/remnawave-installer/.env)
  -n, --non-interactive Не задавать вопросов. При нехватке обязательных
                        параметров скрипт завершится с ошибкой
      --no-save-env     Не сохранять введённые ответы в файл конфигурации
  -h, --help            Показать эту справку

Параметры конфигурации (файл .env или переменные окружения):

  Обязательные:
    NETBIRD_SETUP_KEY     Ключ из панели app.netbird.io
    INSTANCE_NAME         Имя ноды для метрик, например de-node-01
    VICTORIA_METRICS_URL  IP или URL Victoria Metrics
    PANEL_NETBIRD_IP      NetBird IP панели Remnawave (100.x.x.x)

  Необязательные:
    NODE_PORT             Порт для связи с панелью (по умолчанию 2222)
    XRAY_PORT             Порт входящих VPN-подключений (по умолчанию 443)
    SSH_PORTS             Порты SSH через пробел, например "22 2233".
                          Если не задан — определяются автоматически
    SECRET_KEY            Ключ ноды из панели. Если не задан, в
                          docker-compose.yml пишется плейсхолдер

Приоритет источников: переменная окружения → файл конфигурации →
значение по умолчанию → интерактивный вопрос.

Примеры:
  # Обычная интерактивная установка; ответы сохранятся в .env
  sudo ./setup_remnawave_node.sh

  # Полностью автоматическая установка из файла
  sudo ./setup_remnawave_node.sh --config /root/node.conf --non-interactive

  # Общие параметры в файле, уникальные — через окружение
  sudo INSTANCE_NAME=de-node-02 SECRET_KEY=xxx \
       ./setup_remnawave_node.sh --non-interactive

Важно: переменные указывайте ПОСЛЕ sudo. Запись вида
"VAR=x sudo ./script" не сработает — sudo очищает окружение.
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
        echo "#   sudo ./setup_remnawave_node.sh --config $ENV_FILE --non-interactive"
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
    echo -e "${BLUE}║         Настройка параметров Remnawave Node v3.2.1                 ║${NC}"
    echo -e "${BLUE}╚════════════════════════════════════════════════════════════════════╝${NC}"
    echo ""

    if (( NON_INTERACTIVE == 1 )); then
        log_info "Неинтерактивный режим: вопросы задаваться не будут"
    fi

    # ─── NetBird Setup Key ───
    if [[ -z "$NETBIRD_SETUP_KEY" ]]; then
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
    if [[ -z "$INSTANCE_NAME" ]]; then
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

    # ─── XRAY_PORT (необязательный, есть значение по умолчанию) ───
    if [[ -n "$XRAY_PORT" ]] && ! validate_port "$XRAY_PORT"; then
        if (( NON_INTERACTIVE == 1 )); then
            log_error "Некорректное значение XRAY_PORT='$XRAY_PORT' (ожидается 1–65535)"
            exit 1
        fi
        log_warning "Некорректное значение XRAY_PORT='$XRAY_PORT' — запросим заново"
        XRAY_PORT=""
    fi
    if [[ -z "$XRAY_PORT" ]]; then
        if (( NON_INTERACTIVE == 1 )); then
            XRAY_PORT="$DEFAULT_XRAY_PORT"
        else
            while true; do
                local xray_port_input=""
                read -rp "$(echo -e "${YELLOW}XRAY_PORT${NC} для входящих VPN подключений [по умолчанию: ${DEFAULT_XRAY_PORT}]: ")" xray_port_input < /dev/tty
                xray_port_input="${xray_port_input:-$DEFAULT_XRAY_PORT}"
                if validate_port "$xray_port_input"; then
                    XRAY_PORT="$xray_port_input"
                    break
                fi
                echo -e "${RED}Некорректный порт. Введите число от 1 до 65535${NC}"
            done
        fi
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
    log_info "NetBird Setup Key:      [СКРЫТ]"
    log_info "Название инстанса:      $INSTANCE_NAME"
    log_info "Victoria Metrics URL:   $VICTORIA_METRICS_URL"
    log_info "NODE_PORT:              $NODE_PORT"
    log_info "XRAY_PORT:              $XRAY_PORT"
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
                log_error "Попробуйте вручную: systemctl stop unattended-upgrades && sudo ./setup_remnawave_node.sh"
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
    mkdir -p "$TMP_DIR"  # временная директория для параллельных загрузок
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
# Настройка UFW Firewall
#
# Открываем XRAY_PORT для TCP и UDP — Reality может
# работать через обоих. NODE_PORT открываем только для
# NetBird-адреса панели: панель обращается к ноде через
# mesh-сеть, поэтому источником пакетов будет её адрес
# в NetBird, а не публичный IP.
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

    # XRAY_PORT — для всех входящих (клиентские подключения)
    # Открываем и TCP, и UDP: Reality+TCP и возможные QUIC-транспорты
    ufw allow "$XRAY_PORT"/tcp comment "Xray TCP" >> "$LOG_FILE" 2>&1
    ufw allow "$XRAY_PORT"/udp comment "Xray UDP" >> "$LOG_FILE" 2>&1
    log_info "✓ XRAY_PORT $XRAY_PORT: разрешён TCP + UDP"

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

    if [[ -n "$NETBIRD_IP" ]]; then
        log "✓ NetBird IP: ${GREEN}$NETBIRD_IP${NC}"
    else
        log_warning "Не удалось автоматически определить NetBird IP"
        log_info "Запустите вручную: netbird status"
    fi
}

# ─────────────────────────────────────────────────
# Генерация docker-compose.yml для Remnawave Node
#
# Создаётся шаблон на основе официального docker-compose remnanode.
# SECRET_KEY запрашивается у пользователя — его выдаёт панель Remnawave
# при создании ноды. Использует network_mode: host, поэтому явные port
# mappings не нужны — порты настраиваются внутри контейнера через env.
# ─────────────────────────────────────────────────
generate_docker_compose() {
    log "Генерация docker-compose.yml для Remnawave Node..."

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

# Heredoc специально начинается с колонки 0.
# network_mode: host — контейнер напрямую использует сетевой стек хоста,
# поэтому порты открываются через UFW (уже настроен выше), а не через
# Docker port mapping.
cat > "$PROJECT_DIR/docker-compose.yml" <<EOF
services:
  remnanode:
    container_name: remnanode
    hostname: remnanode
    image: remnawave/node:latest
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
      - XRAY_PORT=${XRAY_PORT}
      - SECRET_KEY=${secret_key}
    volumes:
      - /var/log/remnanode:/var/log/remnanode
EOF

    log "✓ docker-compose.yml создан: $PROJECT_DIR/docker-compose.yml"

    if [[ "$secret_key" == "REPLACE_WITH_SECRET_KEY_FROM_PANEL" ]]; then
        log_warning "Перед запуском замените SECRET_KEY в docker-compose.yml"
    fi
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

    echo -e "${BLUE}📊 Мониторинг (linux-${ARCH_SUFFIX}):${NC}"
    echo -e "   ✓ cAdvisor v${CADVISOR_VERSION}       → 127.0.0.1:9101"
    echo -e "   ✓ Node Exporter v${NODE_EXPORTER_VERSION}  → 127.0.0.1:9100"
    echo -e "   ✓ vmagent v${VMAGENT_VERSION}       → 127.0.0.1:8429"
    echo -e "   Instance label: ${GREEN}$INSTANCE_NAME${NC}"
    echo -e "   Remote write:   ${GREEN}$VICTORIA_METRICS_URL${NC}"
    echo ""

    echo -e "${BLUE}🔒 Firewall (UFW):${NC}"
    echo -e "   ✓ SSH ${SSH_PORT_LIST[*]}          — разрешён (TCP)"
    echo -e "   ✓ NODE_PORT $NODE_PORT  — только для $PANEL_NETBIRD_IP (NetBird, TCP)"
    echo -e "   ✓ XRAY_PORT $XRAY_PORT — все (TCP + UDP)"
    echo ""

    echo -e "${BLUE}📝 Следующие шаги:${NC}"
    echo ""
    echo -e "  ${YELLOW}1.${NC} Войдите в панель Remnawave: Nodes → Management → [+]"
    echo -e "     Node Address: ${GREEN}${NETBIRD_IP:-<netbird_ip>}${NC}"
    echo -e "     Node Port:    ${GREEN}$NODE_PORT${NC}"
    echo ""
    echo -e "  ${YELLOW}2.${NC} Скопируйте SECRET_KEY из панели и добавьте в:"
    echo -e "     ${GREEN}nano $PROJECT_DIR/docker-compose.yml${NC}"
    echo ""
    echo -e "  ${YELLOW}3.${NC} Запустите контейнер ноды:"
    echo -e "     ${GREEN}cd $PROJECT_DIR && docker compose up -d${NC}"
    echo -e "     ${GREEN}docker compose logs -f -t${NC}"
    echo ""
    echo -e "  ${YELLOW}4.${NC} В панели нажмите Next → выберите Config Profile → Create"
    echo ""
    echo -e "${BLUE}🔍 Полезные команды:${NC}"
    echo -e "   systemctl status cadvisor nodeexporter vmagent"
    echo -e "   journalctl -u vmagent -f"
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
    echo -e "${GREEN}   Remnawave Node Auto-Installer v3.2.1                    ${NC}"
    echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"
    echo ""

    # Проверка root идёт первой: touch /var/log/... без прав выдал бы
    # "Permission denied" вместо понятного сообщения
    check_root
    touch "$LOG_FILE"

    load_env_file
    detect_arch
    resolve_params

    # Параметры собраны и проверены — сохраняем их для повторного
    # запуска. В неинтерактивном режиме файлом управляет пользователь,
    # поэтому не трогаем его.
    if (( NON_INTERACTIVE == 0 )); then
        save_env_file
    fi

    log "Начало установки..."

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

    # Безопасность
    configure_firewall

    # docker-compose.yml для ноды
    generate_docker_compose

    # Повторное сохранение: SSH_PORTS и SECRET_KEY становятся
    # известны уже после первого сохранения
    if (( NON_INTERACTIVE == 0 )); then
        save_env_file
    fi

    # Финал
    get_netbird_ip
    show_next_steps

    log "Установка завершена успешно."
}

main "$@"
