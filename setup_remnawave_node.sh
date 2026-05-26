#!/bin/bash

#####################################################
# Скрипт автоматической настройки Remnawave Node
# Версия: 3.0
#
# Улучшения по сравнению с v2.1:
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
# Параметры (заполняются интерактивно)
# ─────────────────────────────────────────────────
NETBIRD_SETUP_KEY=""
INSTANCE_NAME=""
VICTORIA_METRICS_URL=""
NODE_PORT=""
XRAY_PORT=""
PANEL_IP=""
NETBIRD_IP=""
ARCH_SUFFIX=""   # Определяется автоматически

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
# Интерактивный сбор параметров
# ─────────────────────────────────────────────────
ask_params() {
    echo ""
    echo -e "${BLUE}╔════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║         Настройка параметров Remnawave Node v3.0                   ║${NC}"
    echo -e "${BLUE}╚════════════════════════════════════════════════════════════════════╝${NC}"
    echo ""

    # NetBird Setup Key
    while [[ -z "$NETBIRD_SETUP_KEY" ]]; do
        read -rp "$(echo -e "${YELLOW}NetBird Setup Key${NC} (из панели app.netbird.io): ")" NETBIRD_SETUP_KEY < /dev/tty
        [[ -z "$NETBIRD_SETUP_KEY" ]] && echo -e "${RED}Поле обязательно для заполнения${NC}"
    done

    # Название инстанса
    while [[ -z "$INSTANCE_NAME" ]]; do
        read -rp "$(echo -e "${YELLOW}Название инстанса${NC} (например: de-node-01, fi-node-01): ")" INSTANCE_NAME < /dev/tty
        [[ -z "$INSTANCE_NAME" ]] && echo -e "${RED}Поле обязательно для заполнения${NC}"
    done

    # URL Victoria Metrics — принимаем IP или полный URL
    while [[ -z "$VICTORIA_METRICS_URL" ]]; do
        read -rp "$(echo -e "${YELLOW}IP/URL Victoria Metrics${NC} (например: 10.0.0.1 или http://10.0.0.1:8428): ")" vm_input < /dev/tty

        if [[ -z "$vm_input" ]]; then
            echo -e "${RED}Поле обязательно для заполнения${NC}"
            continue
        fi

        # Нормализуем URL: добавляем схему и порт если не указаны
        if [[ "$vm_input" =~ ^https?:// ]]; then
            # Схема уже есть — проверяем наличие порта
            if [[ "$vm_input" =~ :[0-9]+(/|$) ]]; then
                VICTORIA_METRICS_URL="$vm_input"
            else
                VICTORIA_METRICS_URL="${vm_input}:8428"
            fi
        else
            # Только IP/hostname — добавляем схему и порт
            VICTORIA_METRICS_URL="http://${vm_input}:8428"
        fi

        log_info "Сформирован URL Victoria Metrics: $VICTORIA_METRICS_URL"
    done

    # NODE_PORT
    while true; do
        read -rp "$(echo -e "${YELLOW}NODE_PORT${NC} для связи с панелью [по умолчанию: 2222]: ")" node_port_input < /dev/tty
        node_port_input="${node_port_input:-2222}"

        if validate_port "$node_port_input"; then
            NODE_PORT="$node_port_input"
            break
        else
            echo -e "${RED}Некорректный порт. Введите число от 1 до 65535${NC}"
        fi
    done

    # XRAY_PORT
    while true; do
        read -rp "$(echo -e "${YELLOW}XRAY_PORT${NC} для входящих VPN подключений [по умолчанию: 443]: ")" xray_port_input < /dev/tty
        xray_port_input="${xray_port_input:-443}"

        if validate_port "$xray_port_input"; then
            XRAY_PORT="$xray_port_input"
            break
        else
            echo -e "${RED}Некорректный порт. Введите число от 1 до 65535${NC}"
        fi
    done

    # IP панели Remnawave
    while true; do
        read -rp "$(echo -e "${YELLOW}IP адрес панели Remnawave${NC} (для правила UFW): ")" PANEL_IP < /dev/tty

        if [[ -z "$PANEL_IP" ]]; then
            echo -e "${RED}Поле обязательно для заполнения${NC}"
        elif validate_ip "$PANEL_IP"; then
            break
        else
            echo -e "${RED}Некорректный IPv4-адрес. Пример: 192.168.1.1${NC}"
        fi
    done

    echo ""
    echo -e "${CYAN}──────────────── Введённые параметры ────────────────${NC}"
    log_info "NetBird Setup Key: [СКРЫТ]"
    log_info "Название инстанса:    $INSTANCE_NAME"
    log_info "Victoria Metrics URL: $VICTORIA_METRICS_URL"
    log_info "NODE_PORT:            $NODE_PORT"
    log_info "XRAY_PORT:            $XRAY_PORT"
    log_info "IP панели Remnawave:  $PANEL_IP"
    echo ""
}

# ─────────────────────────────────────────────────
# Шаг 1: Обновление системы
# ─────────────────────────────────────────────────
update_system() {
    log "Шаг 1/4: Обновление системных пакетов..."

    export DEBIAN_FRONTEND=noninteractive

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
        if curl -fsSL https://pkgs.netbird.io/install.sh | sh >> "$LOG_FILE" 2>&1; then
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

    if command -v docker &> /dev/null; then
        local ver
        ver=$(docker --version)
        log_warning "Docker уже установлен ($ver), пропускаем"
    else
        if curl -fsSL https://get.docker.com | sh >> "$LOG_FILE" 2>&1; then
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
# Вспомогательная функция: проверка версии бинарника
# Возвращает версию или "none" если файла нет
# ─────────────────────────────────────────────────
get_binary_version() {
    local binary="$1"
    local version_flag="${2:---version}"

    if [[ ! -f "$binary" ]]; then
        echo "none"
        return
    fi

    set +e
    local ver
    ver=$("$binary" "$version_flag" 2>&1 | grep -oP '\d+\.\d+\.\d+' | head -n1)
    set -e

    echo "${ver:-unknown}"
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
        current_ver=$(get_binary_version "$target" "--version")

        if [[ "$current_ver" == "$CADVISOR_VERSION" ]]; then
            echo "SKIP: cAdvisor v${CADVISOR_VERSION} уже установлен" >> "$log_file"
            echo "0" > "$status_file"
            return
        elif [[ "$current_ver" != "none" ]]; then
            echo "UPDATE: cAdvisor $current_ver → $CADVISOR_VERSION" >> "$log_file"
        fi

        local url="https://github.com/google/cadvisor/releases/download/v${CADVISOR_VERSION}/cadvisor-v${CADVISOR_VERSION}-linux-${ARCH_SUFFIX}"

        if wget -q --timeout=120 --tries=3 \
            -O "${target}.tmp" \
            "$url" >> "$log_file" 2>&1; then
            mv "${target}.tmp" "$target"
            chmod +x "$target"
            echo "OK: cAdvisor v${CADVISOR_VERSION} установлен" >> "$log_file"
            echo "0" > "$status_file"
        else
            echo "FAIL: ошибка при скачивании cAdvisor" >> "$log_file"
            echo "1" > "$status_file"
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
        current_ver=$(get_binary_version "$target" "--version")

        if [[ "$current_ver" == "$NODE_EXPORTER_VERSION" ]]; then
            echo "SKIP: Node Exporter v${NODE_EXPORTER_VERSION} уже установлен" >> "$log_file"
            echo "0" > "$status_file"
            return
        fi

        local archive="node_exporter-${NODE_EXPORTER_VERSION}.linux-${ARCH_SUFFIX}.tar.gz"
        local url="https://github.com/prometheus/node_exporter/releases/download/v${NODE_EXPORTER_VERSION}/${archive}"
        local tmp_archive="${TMP_DIR}/${archive}"

        if wget -q --timeout=120 --tries=3 \
            -O "$tmp_archive" \
            "$url" >> "$log_file" 2>&1; then
            tar -xzf "$tmp_archive" -C "$TMP_DIR" >> "$log_file" 2>&1
            mv "${TMP_DIR}/node_exporter-${NODE_EXPORTER_VERSION}.linux-${ARCH_SUFFIX}/node_exporter" "$target"
            chmod +x "$target"
            # Очищаем распакованную директорию
            rm -rf "${TMP_DIR}/node_exporter-${NODE_EXPORTER_VERSION}.linux-${ARCH_SUFFIX}" "$tmp_archive"
            echo "OK: Node Exporter v${NODE_EXPORTER_VERSION} установлен" >> "$log_file"
            echo "0" > "$status_file"
        else
            echo "FAIL: ошибка при скачивании Node Exporter" >> "$log_file"
            echo "1" > "$status_file"
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
        current_ver=$(get_binary_version "$target" "--version")

        if [[ "$current_ver" == "$VMAGENT_VERSION" ]]; then
            echo "SKIP: vmagent v${VMAGENT_VERSION} уже установлен" >> "$log_file"
            echo "0" > "$status_file"
            return
        fi

        # Для arm64 VictoriaMetrics использует суффикс "arm64" в архиве
        local vm_arch="$ARCH_SUFFIX"
        local archive="vmutils-linux-${vm_arch}-v${VMAGENT_VERSION}.tar.gz"
        local url="https://github.com/VictoriaMetrics/VictoriaMetrics/releases/download/v${VMAGENT_VERSION}/${archive}"
        local tmp_archive="${TMP_DIR}/${archive}"

        if wget -q --timeout=120 --tries=3 \
            -O "$tmp_archive" \
            "$url" >> "$log_file" 2>&1; then
            tar -xzf "$tmp_archive" -C "$TMP_DIR" >> "$log_file" 2>&1
            mv "${TMP_DIR}/vmagent-prod" "$target"
            chmod +x "$target"
            rm -f "$tmp_archive"
            # Удаляем прочие бинарники из vmutils (vmbackup, vmctl и т.д.)
            find "$TMP_DIR" -maxdepth 1 -name "*-prod" -delete 2>/dev/null || true
            echo "OK: vmagent v${VMAGENT_VERSION} установлен" >> "$log_file"
            echo "0" > "$status_file"
        else
            echo "FAIL: ошибка при скачивании vmagent" >> "$log_file"
            echo "1" > "$status_file"
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
    # даже при ошибке внутри функции, поэтому используем файл статуса)
    local components=("cadvisor" "nodeexporter" "vmagent")
    for comp in "${components[@]}"; do
        local status_file="$TMP_DIR/${comp}.status"
        local log_file="$TMP_DIR/${comp}.log"

        # Пишем лог компонента в основной лог
        if [[ -f "$log_file" ]]; then
            cat "$log_file" >> "$LOG_FILE"
        fi

        if [[ ! -f "$status_file" ]]; then
            log_error "Файл статуса для $comp не найден (загрузка не завершилась)"
            has_error=1
        else
            local status
            status=$(cat "$status_file")
            if [[ "$status" == "0" ]]; then
                local msg
                msg=$(cat "$log_file" 2>/dev/null | head -n1 || echo "OK")
                log_info "✓ $comp: $msg"
            elif [[ "$status" == "SKIP"* ]]; then
                log_warning "$comp: уже актуальной версии, пропущен"
            else
                log_error "Ошибка при установке $comp. Подробности: $log_file"
                has_error=1
            fi
        fi
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
# Настройка UFW Firewall
#
# Открываем XRAY_PORT для TCP и UDP — Reality может
# работать через обоих. NODE_PORT открываем только для
# IP панели, чтобы ограничить доступ.
# ─────────────────────────────────────────────────
configure_firewall() {
    log "Настройка UFW Firewall..."

    if ! command -v ufw &> /dev/null; then
        log_info "UFW не установлен, устанавливаем..."
        apt install -y ufw >> "$LOG_FILE" 2>&1
        log_info "✓ UFW установлен"
    fi

    # SSH — разрешаем в первую очередь, чтобы не потерять доступ
    ufw allow OpenSSH >> "$LOG_FILE" 2>&1
    log_info "✓ OpenSSH: разрешён"

    # NODE_PORT — только для IP панели
    ufw allow from "$PANEL_IP" to any port "$NODE_PORT" proto tcp \
        comment "Remnawave panel → node" >> "$LOG_FILE" 2>&1
    log_info "✓ NODE_PORT $NODE_PORT: разрешён только для $PANEL_IP"

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

    local secret_key=""

    echo ""
    echo -e "${CYAN}──────────── SECRET_KEY для Remnawave Node ────────────${NC}"
    echo -e "${YELLOW}SECRET_KEY выдаётся панелью Remnawave при создании ноды.${NC}"
    echo -e "${YELLOW}Если ключ уже есть — вставьте его сейчас.${NC}"
    echo -e "${YELLOW}Или нажмите Enter, чтобы заполнить вручную позже.${NC}"
    echo ""

    read -rp "$(echo -e "${YELLOW}SECRET_KEY${NC} (или Enter для пропуска): ")" secret_key < /dev/tty

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
    echo -e "   ✓ OpenSSH              — разрешён"
    echo -e "   ✓ NODE_PORT $NODE_PORT  — только для $PANEL_IP (TCP)"
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
    echo ""
}

# ─────────────────────────────────────────────────
# Точка входа
# ─────────────────────────────────────────────────
main() {
    echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}   Remnawave Node Auto-Installer v3.0                      ${NC}"
    echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"
    echo ""

    touch "$LOG_FILE"

    check_root
    detect_arch
    ask_params

    log "Начало установки..."

    # Базовые компоненты
    update_system
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

    # Финал
    get_netbird_ip
    show_next_steps

    log "Установка завершена успешно."
}

main
